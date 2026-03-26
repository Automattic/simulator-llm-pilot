# frozen_string_literal: true

module SimulatorLLMPilot
  # Orchestrates the full test run:
  # 1. Discover tests
  # 2. Resolve simulator
  # 3. Start WDA
  # 4. Run each test via Agent (with runner-level state reset between tests)
  # 5. Write results with runner-enforced metadata
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
      test_cases.each_with_index.map do |test_case, index|
        @logger.info ''
        @logger.info '=' * 60
        @logger.info "[#{index + 1}/#{test_cases.length}] #{test_case.title}"
        @logger.info '=' * 60

        reset_app_state!

        result = prepare_session!(wda, test_case)
        result ||= run_test_case(test_case, wda, llm)
        result[:test] = test_case.title
        result[:file] = test_case.file_path

        log_result(result)
        result
      end
    end

    def prepare_session!(wda, test_case)
      wda.create_session
      nil
    rescue StandardError => e
      {
        status: 'infra_error',
        reason: "Failed to create WDA session: #{e.message}",
        model_status: 'infra_error',
        model_reason: "Failed to create WDA session: #{e.message}",
        enforced_failures: [],
        tool_usage: {},
        verification_expected: TestParser.expects_verification?(test_case),
        verification_ran: false,
        verification_satisfied: false,
        cleanup_expected: TestParser.expects_cleanup?(test_case),
        cleanup_ran: false,
        cleanup_satisfied: false,
        turns: 0,
        total_infra_errors: 1
      }
    end

    def run_test_case(test_case, wda, llm)
      Agent.new(
        test_case: test_case,
        config: @config,
        wda: wda,
        simulator: @simulator,
        llm: llm,
        logger: @logger
      ).run
    end

    def reset_app_state!
      @simulator.terminate_app(@config.simulator_udid, @config.app_bundle_id)
      @logger.debug 'Terminated app for clean state'
    rescue StandardError => e
      @logger.debug "App terminate (pre-test reset): #{e.message}"
    end

    def log_result(result)
      status = result[:status]
      icon = case status
             when 'pass' then 'PASS'
             when 'infra_error' then 'INFRA'
             else 'FAIL'
             end

      @logger.info "[#{icon}] #{result[:test]}"
      @logger.info "  #{result[:reason]}"
      @logger.warn "  Runner enforcement: #{result[:enforced_failures].join('; ')}" if result[:enforced_failures]&.any?
      log_section_warning('Verification', result[:verification_expected], result[:verification_ran], result[:verification_satisfied])
      log_section_warning('Cleanup', result[:cleanup_expected], result[:cleanup_ran], result[:cleanup_satisfied])
    end

    def log_section_warning(label, expected, ran, satisfied)
      return unless expected
      return if ran && satisfied

      message = if ran
                  "#{label} REST calls ran but did not finish successfully"
                else
                  "#{label} section exists but no matching REST call ran"
                end
      @logger.warn "  #{message}"
    end

    def resolve_simulator!
      if @config.simulator_udid
        @logger.info "Simulator UDID: #{@config.simulator_udid}"
        return
      end

      if @config.simulator_name
        device = @simulator.booted_device(name: @config.simulator_name)
        if device
          @config.simulator_udid = device[:udid]
          @logger.info "Using requested simulator: #{device[:name]} (#{device[:udid]})"
          return
        end

        @logger.info "Booting simulator: #{@config.simulator_name}..."
        @simulator.boot(@config.simulator_name)
        sleep 5
        device = @simulator.booted_device(name: @config.simulator_name)
        if device
          @config.simulator_udid = device[:udid]
          @logger.info "Booted: #{device[:name]} (#{device[:udid]})"
          return
        end

        raise "Simulator '#{@config.simulator_name}' did not reach the Booted state.\n" \
              'Specify --simulator-udid explicitly if you need a different device.'
      end

      device = @simulator.booted_device
      if device
        @config.simulator_udid = device[:udid]
        @logger.info "Auto-detected simulator: #{device[:name]} (#{device[:udid]})"
        return
      end

      raise "No booted simulator found. Boot one with:\n  " \
            "xcrun simctl boot 'iPhone 16'\n" \
            'Or specify --simulator-udid or --simulator-name.'
    end

    def setup_results_dir!
      timestamp = Time.now.strftime('%Y-%m-%d-%H%M')
      @config.results_dir ||= File.join(Dir.pwd, 'results', timestamp)
      @config.screenshots_dir ||= File.join(@config.results_dir, 'screenshots')
      FileUtils.mkdir_p(@config.results_dir)
      FileUtils.mkdir_p(@config.screenshots_dir)
      @logger.info "Results: #{@config.results_dir}"
    end

    def start_wda!
      wda_path = @config.wda_project_path ||
                 File.join(Dir.pwd, '.build', 'WebDriverAgent', 'WebDriverAgent.xcodeproj')
      @config.wda_project_path = wda_path
      wda_derived_data_path = File.join(File.dirname(wda_path), 'DerivedData')

      @wda_lifecycle.start(
        udid: @config.simulator_udid,
        wda_project_path: wda_path,
        wda_derived_data_path: wda_derived_data_path
      )
    end

    def write_results(results)
      passed = results.count { |result| result[:status] == 'pass' }
      failed = results.count { |result| result[:status] == 'fail' }
      infra = results.count { |result| result[:status] == 'infra_error' }
      enforced = results.count { |result| result[:enforced_failures]&.any? }

      lines = [
        "# Test Results\n",
        "- **Date:** #{Time.now.strftime('%Y-%m-%d %H:%M')}",
        "- **Site:** #{@config.site_url}",
        "- **Model:** #{@config.anthropic_model}",
        "- **Total:** #{results.length} | **Passed:** #{passed} | **Failed:** #{failed}" \
        "#{" | **Infra errors:** #{infra}" if infra.positive?}" \
        "#{" | **Enforced failures:** #{enforced}" if enforced.positive?}\n",
        "## Results\n"
      ]

      results.each do |result|
        status_label = case result[:status]
                       when 'pass' then 'PASS'
                       when 'infra_error' then 'INFRA_ERROR'
                       else 'FAIL'
                       end

        lines << "### #{status_label} #{result[:test]}"
        lines << result[:reason].to_s
        lines << "Model status: #{result[:model_status]} | Turns: #{result[:turns]} | Total infra errors: #{result[:total_infra_errors]}"
        lines << "Verification: #{section_state(result[:verification_expected], result[:verification_ran], result[:verification_satisfied])}"
        lines << "Cleanup: #{section_state(result[:cleanup_expected], result[:cleanup_ran], result[:cleanup_satisfied])}"
        lines << "Tools: #{format_tool_usage(result[:tool_usage])}"
        lines << "Runner enforcement: #{result[:enforced_failures].join('; ')}" if result[:enforced_failures]&.any?
        lines << ''
      end

      path = File.join(@config.results_dir, 'results.md')
      File.write(path, lines.join("\n"))
      @logger.info "Results written to #{path}"
    end

    def print_summary(results)
      passed = results.count { |result| result[:status] == 'pass' }
      failed = results.count { |result| result[:status] == 'fail' }
      infra = results.count { |result| result[:status] == 'infra_error' }
      enforced = results.count { |result| result[:enforced_failures]&.any? }

      @logger.info ''
      @logger.info '=' * 60
      summary = "DONE — Total: #{results.length} | Passed: #{passed} | Failed: #{failed}"
      summary += " | Infra errors: #{infra}" if infra.positive?
      summary += " | Enforced failures: #{enforced}" if enforced.positive?
      @logger.info summary
      @logger.info "Results: #{@config.results_dir}"
      @logger.info '=' * 60
    end

    def section_state(expected, ran, satisfied)
      return 'not declared' unless expected
      return 'passed' if ran && satisfied
      return 'missing' unless ran

      'failed'
    end

    def format_tool_usage(tool_usage)
      return 'none' if tool_usage.nil? || tool_usage.empty?

      tool_usage.map { |name, count| "#{name}(#{count})" }.join(', ')
    end
  end
end
