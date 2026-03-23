# frozen_string_literal: true

module SimPilot
  # Executes tool calls from the LLM against the actual simulator/WDA/REST API.
  # This is the enforcement layer — only these operations are possible.
  class ToolExecutor
    MAX_REST_RESPONSE_CHARS = 2_000

    attr_reader :test_completed, :test_status, :test_reason,
                :total_infra_errors, :consecutive_infra_errors,
                :tool_usage, :rest_api_usage

    def initialize(wda:, simulator:, config:, logger:)
      @wda = wda
      @simulator = simulator
      @config = config
      @logger = logger
      @test_completed = false
      @test_status = nil
      @test_reason = nil
      @screenshot_count = 0
      @total_infra_errors = 0
      @consecutive_infra_errors = 0
      @tool_usage = Hash.new(0)
      @rest_api_usage = Hash.new do |hash, purpose|
        hash[purpose] = {
          calls: 0,
          successes: 0,
          failures: 0,
          last_status: nil,
          last_success: false,
          last_error: nil
        }
      end
    end

    def execute(tool_name, input)
      @tool_usage[tool_name] += 1
      @logger.debug "Tool call: #{tool_name}(#{truncate(input.to_json, 200)})"

      result = case tool_name
               when "get_accessibility_tree" then exec_get_tree
               when "tap"                    then exec_tap(input)
               when "tap_element"            then exec_tap_element(input)
               when "swipe"                  then exec_swipe(input)
               when "type_text"              then exec_type_text(input)
               when "clear_text"             then exec_clear_text
               when "take_screenshot"        then exec_screenshot(input)
               when "launch_app"             then exec_launch_app
               when "rest_api_call"          then exec_rest_api(input)
               when "wait"                   then exec_wait(input)
               when "complete_test"          then exec_complete_test(input)
               else "Unknown tool: #{tool_name}"
               end

      @consecutive_infra_errors = 0
      @logger.debug "Tool result: #{truncate(result.to_s, 300)}"
      result
    rescue InfraError => e
      @total_infra_errors += 1
      @consecutive_infra_errors += 1
      msg = "INFRASTRUCTURE ERROR: #{e.message}"
      @logger.error msg
      msg
    rescue StandardError => e
      @consecutive_infra_errors = 0
      @logger.error "Tool #{tool_name} error: #{e.message}"
      "Error: #{e.message}"
    end

    def rest_api_called?(purpose = nil)
      return @tool_usage["rest_api_call"] > 0 if purpose.nil?

      @rest_api_usage[purpose][:calls] > 0
    end

    def rest_api_satisfied?(purpose)
      usage = @rest_api_usage[purpose]
      usage[:calls] > 0 && usage[:last_success]
    end

    private

    def exec_get_tree
      tree = @wda.get_tree(format: :description)
      raise InfraError, "Empty accessibility tree — WDA session may have expired" if tree.nil? || tree.empty?

      tree
    end

    def exec_tap(input)
      x, y = input.values_at("x", "y")
      @wda.tap_at(x, y)
      @logger.info "  Tapped (#{x}, #{y})"
      "Tapped at (#{x}, #{y})"
    end

    def exec_tap_element(input)
      identifier = input["identifier"]
      label = input["label"]
      element_id = nil

      element_id = @wda.find_element(using: "accessibility id", value: identifier) if identifier
      element_id = @wda.find_element(using: "link text", value: label) if element_id.nil? && label

      if element_id.nil?
        target = identifier || label || "(no identifier or label provided)"
        return "Element not found: #{target}. Use get_accessibility_tree and tap by coordinates instead."
      end

      @wda.click_element(element_id)
      target = identifier || label
      @logger.info "  Tapped element '#{target}'"
      "Tapped element: #{target}"
    end

    def exec_swipe(input)
      x1, y1, x2, y2 = input.values_at("x1", "y1", "x2", "y2")
      duration = input["duration"] || 500
      @wda.swipe(x1, y1, x2, y2, duration: duration)
      @logger.info "  Swiped (#{x1},#{y1}) -> (#{x2},#{y2})"
      "Swiped from (#{x1}, #{y1}) to (#{x2}, #{y2})"
    end

    def exec_type_text(input)
      text = input["text"]
      @wda.type_text(text)
      display = text.length > 40 ? "#{text[0..39]}..." : text
      @logger.info "  Typed '#{display}'"
      "Typed: #{text}"
    end

    def exec_clear_text
      @wda.clear_text
      @logger.info "  Cleared text field"
      "Text field cleared"
    end

    def exec_screenshot(input)
      label = input["label"] || "screenshot"
      @screenshot_count += 1
      safe_label = label.gsub(/[^a-zA-Z0-9_-]/, "_")
      filename = "#{safe_label}-#{@screenshot_count}.png"

      dir = @config.screenshots_dir || "/tmp"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, filename)

      @simulator.screenshot(@config.simulator_udid, path)
      @logger.info "  Screenshot: #{path}"
      "Screenshot saved to #{path}"
    end

    def exec_launch_app
      args = {
        "ui-testing" => "YES",
        "ui-test-reset-everything" => "YES",
        "ui-test-disable-prompts" => "YES",
        "ui-test-disable-animations" => "YES",
        "ui-test-disable-migration" => "YES",
        "ui-test-site-url" => @config.site_url,
        "ui-test-site-user" => @config.username,
        "ui-test-site-pass" => @config.app_password
      }
      @simulator.launch_app(@config.simulator_udid, @config.app_bundle_id, args: args)
      "App launched with test credentials and UI testing flags (reset state, disabled prompts/animations). " \
        "Wait 2-3 seconds for it to load."
    end

    def exec_rest_api(input)
      purpose = input["purpose"]
      method = input["method"]
      path = input["path"]
      body = input["body"]
      query = input["query"]

      validate_rest_api_purpose!(purpose)
      validate_rest_api_path!(path)

      uri = URI("#{@config.site_url}#{path}")
      if query
        params = URI.encode_www_form(query)
        uri.query = uri.query ? "#{uri.query}&#{params}" : params
      end

      request = build_http_request(method, uri)
      request["Content-Type"] = "application/json"
      credentials = Base64.strict_encode64("#{@config.username}:#{@config.app_password}")
      request["Authorization"] = "Basic #{credentials}"
      request.body = JSON.generate(body) if body

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.read_timeout = 30
        http.open_timeout = 10
        http.request(request)
      end

      status_code = response.code.to_i
      success = status_code.between?(200, 299)
      record_rest_api_result(purpose, success: success, status: status_code, error: nil)
      @logger.info "  REST #{purpose} #{method} #{path} -> #{response.code}"

      "HTTP #{response.code}\n#{format_rest_response_body(response.body)}"
    rescue StandardError => e
      record_rest_api_result(purpose, success: false, status: nil, error: e.message) if purpose
      raise
    end

    def exec_wait(input)
      seconds = [[input["seconds"].to_f, 10].min, 0.1].max
      sleep(seconds)
      "Waited #{seconds} seconds"
    end

    def exec_complete_test(input)
      @test_completed = true
      @test_status = input["status"]
      @test_reason = input["reason"]
      @logger.info "  Test result: #{@test_status.upcase} — #{@test_reason}"
      "Test marked as #{@test_status}: #{@test_reason}"
    end

    def validate_rest_api_purpose!(purpose)
      return if %w[setup verification cleanup].include?(purpose)

      raise "REST API purpose '#{purpose}' is not allowed. " \
            "Use setup, verification, or cleanup."
    end

    def validate_rest_api_path!(path)
      allowed = @config.rest_api_allowed_prefix
      return if allowed.nil? || allowed.empty?
      return if path.start_with?(allowed)

      raise "REST API path '#{path}' is not allowed. " \
            "Only paths starting with '#{allowed}' are permitted."
    end

    def build_http_request(method, uri)
      case method
      when "GET"    then Net::HTTP::Get.new(uri)
      when "POST"   then Net::HTTP::Post.new(uri)
      when "PUT"    then Net::HTTP::Put.new(uri)
      when "DELETE" then Net::HTTP::Delete.new(uri)
      else raise "Unsupported HTTP method: #{method}"
      end
    end

    def record_rest_api_result(purpose, success:, status:, error:)
      usage = @rest_api_usage[purpose]
      usage[:calls] += 1
      success ? usage[:successes] += 1 : usage[:failures] += 1
      usage[:last_status] = status
      usage[:last_success] = success
      usage[:last_error] = error
    end

    def format_rest_response_body(body)
      text = begin
        JSON.pretty_generate(JSON.parse(body))
      rescue JSON::ParserError
        body.to_s
      end

      truncate(text, MAX_REST_RESPONSE_CHARS)
    end

    def truncate(str, max)
      str.length > max ? "#{str[0...max]}..." : str
    end
  end
end
