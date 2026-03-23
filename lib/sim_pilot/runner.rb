# frozen_string_literal: true

module SimPilot
  # Orchestrates the full test run:
  # 1. Discover tests
  # 2. Resolve simulator
  # 3. Start WDA
  # 4. Run each test via Agent (with runner-level state reset between tests)
  # 5. Write results with verification observability metadata
  # 6. Stop WDA
  class Runner
    def initialize(config:, logger:)
      @config = config
      @logger = logger
      @simulator = Simulator.new(logger: logger)
      @wda_lifecycle = WDALifecycle.new(port: config.wda_port, logger: logger)
    end

    def run(test_path)
      test_cases = TestParser.discover(test_path)
      if test_cases.empty?
        @logger.error "No test files found at #{test_path}"
        return []
      end
      @logger.info "Found #{test_cases.length} test(s)"

      resolve_simulator!
      setup_results_dir!
      start_wda!

      wda = WDAClient.new(port: @config.wda_port, logger: @logger)
      wda.create_session

      llm = LLMClient.new(
        api_key: @config.anthropic_api_key,
        model: @config.anthropic_model,
        logger: @logger
      )

      results = run_tests(test_cases, wda, llm)
      write_results(results)
      print_summary(results)
      results
    ensure
      @wda_lifecycle&.stop
    end

    private

    def run_tests(test_cases, wda, llm)
      results = []

      test_cases.each_with_index do |test_case, index|
        @logger.info ""
        @logger.info "=" * 60
        @logger.info "[#{index + 1}/#{test_cases.length}] #{test_case.title}"
        @logger.info "=" * 60

        # Runner-level clean state: terminate app before each test
        # This is infrastructure-enforced, not agent-controlled
        reset_app_state!

        agent = Agent.new(
          test_case: test_case,
          config: @config,
          wda: wda,
          simulator: @simulator,
          llm: llm,
          logger: @logger
        )

        result = agent.run
        result[:test] = test_case.title
        result[:file] = test_case.file_path
        results << result

        log_result(result)

        # Recreate WDA session between tests
        recreate_session(wda)
      end

      results
    end

    def reset_app_state!
      @simulator.terminate_app(@config.simulator_udid, @config.app_bundle_id)
      @logger.debug "Terminated app for clean state"
    rescue StandardError => e
      @logger.debug "App terminate (pre-test reset): #{e.message}"
    end

    def log_result(result)
      status = result[:status]
      icon = case status
             when "pass" then "PASS"
             when "infra_error" then "INFRA"
             else "FAIL"
             end

      @logger.info "[#{icon}] #{result[:test]}"
      @logger.info "  #{result[:reason]}"

      # Verification observability warnings
      if result[:verification_expected] && !result[:verification_ran]
        @logger.warn "  Test has a Verification section but rest_api_call was never invoked"
      end

      if result[:status] == "pass" && result[:verification_expected] && !result[:verification_ran]
        @logger.warn "  SUSPICIOUS PASS: test passed without running verification"
      end
    end

    def recreate_session(wda)
      wda.create_session
    rescue StandardError => e
      @logger.warn "Failed to recreate WDA session: #{e.message}"
    end

    def resolve_simulator!
      if @config.simulator_udid
        @logger.info "Simulator UDID: #{@config.simulator_udid}"
        return
      end

      device = @simulator.booted_device
      if device
        @config.simulator_udid = device[:udid]
        @logger.info "Auto-detected simulator: #{device[:name]} (#{device[:udid]})"
        return
      end

      if @config.simulator_name
        @logger.info "Booting simulator: #{@config.simulator_name}..."
        @simulator.boot(@config.simulator_name)
        sleep 5
        device = @simulator.booted_device
        if device
          @config.simulator_udid = device[:udid]
          @logger.info "Booted: #{device[:name]} (#{device[:udid]})"
          return
        end
      end

      raise "No booted simulator found. Boot one with:\n" \
            "  xcrun simctl boot 'iPhone 16'\n" \
            "Or specify --simulator-udid or --simulator-name."
    end

    def setup_results_dir!
      timestamp = Time.now.strftime("%Y-%m-%d-%H%M")
      @config.results_dir ||= File.join(Dir.pwd, "results", timestamp)
      @config.screenshots_dir ||= File.join(@config.results_dir, "screenshots")
      FileUtils.mkdir_p(@config.results_dir)
      FileUtils.mkdir_p(@config.screenshots_dir)
      @logger.info "Results: #{@config.results_dir}"
    end

    def start_wda!
      wda_path = @config.wda_project_path ||
                 File.join(Dir.pwd, ".build", "WebDriverAgent", "WebDriverAgent.xcodeproj")
      @config.wda_project_path = wda_path

      @wda_lifecycle.start(
        udid: @config.simulator_udid,
        wda_project_path: wda_path
      )
    end

    def write_results(results)
      passed = results.count { |r| r[:status] == "pass" }
      failed = results.count { |r| r[:status] == "fail" }
      infra = results.count { |r| r[:status] == "infra_error" }

      lines = [
        "# Test Results\n",
        "- **Date:** #{Time.now.strftime("%Y-%m-%d %H:%M")}",
        "- **Site:** #{@config.site_url}",
        "- **Model:** #{@config.anthropic_model}",
        "- **Total:** #{results.length} | **Passed:** #{passed} | **Failed:** #{failed}" \
          "#{" | **Infra errors:** #{infra}" if infra > 0}\n",
        "## Results\n"
      ]

      results.each do |r|
        status_label = case r[:status]
                       when "pass" then "PASS"
                       when "infra_error" then "INFRA_ERROR"
                       else "FAIL"
                       end
        lines << "### #{status_label} #{r[:test]}"
        lines << r[:reason].to_s

        # Verification observability
        if r[:verification_expected] && !r[:verification_ran]
          lines << "**Warning:** Verification section exists but `rest_api_call` was not invoked."
        end

        lines << "Turns: #{r[:turns]} | Tools: #{r[:tool_usage]&.map { |k, v| "#{k}(#{v})" }&.join(", ")}"
        lines << ""
      end

      path = File.join(@config.results_dir, "results.md")
      File.write(path, lines.join("\n"))
      @logger.info "Results written to #{path}"
    end

    def print_summary(results)
      passed = results.count { |r| r[:status] == "pass" }
      failed = results.count { |r| r[:status] == "fail" }
      infra = results.count { |r| r[:status] == "infra_error" }
      suspicious = results.count { |r| r[:status] == "pass" && r[:verification_expected] && !r[:verification_ran] }

      @logger.info ""
      @logger.info "=" * 60
      summary = "DONE — Total: #{results.length} | Passed: #{passed} | Failed: #{failed}"
      summary += " | Infra errors: #{infra}" if infra > 0
      @logger.info summary
      @logger.warn "#{suspicious} test(s) passed without running expected verification" if suspicious > 0
      @logger.info "Results: #{@config.results_dir}"
      @logger.info "=" * 60
    end
  end
end
