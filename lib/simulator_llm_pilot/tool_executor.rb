# frozen_string_literal: true

require 'cgi'

module SimulatorLLMPilot
  # Executes tool calls from the LLM against the actual simulator/WDA/REST API.
  # This is the enforcement layer — only these operations are possible.
  class ToolExecutor
    MAX_REST_RESPONSE_CHARS = 2_000
    DEFAULT_TREE_CHANGE_TIMEOUT_SECONDS = 0.8
    POLL_INTERVAL_SECONDS = 0.3
    MAX_TAP_REPEATS = 30
    REPEAT_TAP_INTERVAL_SECONDS = 0.2
    CLEANUP_DELETE_ONLY_METHODS = {
      'setup' => %w[GET].freeze,
      'verification' => %w[GET].freeze,
      'cleanup' => %w[GET DELETE].freeze
    }.freeze
    # Attributes summarized on found elements so assert/wait results answer
    # "what state is it in", not just "is it there".
    ELEMENT_STATE_ATTRIBUTES = %w[type label value enabled].freeze
    # Hint appended when a tap_element lookup fails. tap_and_wait swaps it for a
    # tree-aware version since it already returns the accessibility tree below.
    ELEMENT_NOT_FOUND_PREFIX = 'Element not found:'
    TAP_BY_COORDINATES_HINT = 'Use get_accessibility_tree and tap by coordinates instead.'
    TREE_UNCHANGED_MESSAGE = '(Accessibility tree unchanged — the last tree returned in this ' \
                             'conversation is still current.)'

    attr_reader :test_completed, :test_status, :test_reason,
                :total_infra_errors, :consecutive_infra_errors,
                :tool_usage, :rest_api_usage, :assertion_usage

    def initialize(wda:, simulator:, config:, logger:)
      @wda = wda
      @simulator = simulator
      @config = config
      @logger = logger
      @test_completed = false
      @test_status = nil
      @test_reason = nil
      @screenshot_count = 0
      @last_tree_for_dedupe = nil
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
      @assertion_usage = Hash.new do |hash, target|
        hash[target] = { calls: 0, failures: 0, last_success: false }
      end
    end

    def execute(tool_name, input)
      @tool_usage[tool_name] += 1
      @logger.debug "Tool call: #{tool_name}(#{truncate(sanitized_debug_input(input), 200)})"

      result = case tool_name
               when 'get_accessibility_tree' then dedupe_tree(exec_get_tree)
               when 'tap'                    then exec_tap(input)
               when 'tap_element'            then exec_tap_element(input)
               when 'tap_and_wait'           then exec_tap_and_wait(input)
               when 'tap_collection_cell'    then exec_tap_collection_cell(input)
               when 'assert_element_exists'  then exec_assert_element(input, expect_present: true)
               when 'assert_element_absent'  then exec_assert_element(input, expect_present: false)
               when 'wait_for_element'       then exec_wait_for_element(input)
               when 'swipe'                  then exec_swipe(input)
               when 'type_text'              then exec_type_text(input)
               when 'clear_text'             then exec_clear_text
               when 'take_screenshot'        then exec_screenshot(input)
               when 'launch_app'             then exec_launch_app
               when 'rest_api_call'          then exec_rest_api(input)
               when 'wait'                   then exec_wait(input)
               when 'complete_test'          then exec_complete_test(input)
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
      return @tool_usage['rest_api_call'].positive? if purpose.nil?
      return false unless @rest_api_usage.key?(purpose)

      @rest_api_usage[purpose][:calls].positive?
    end

    def rest_api_satisfied?(purpose)
      return false unless @rest_api_usage.key?(purpose)

      usage = @rest_api_usage[purpose]
      usage[:calls].positive? && usage[:last_success]
    end

    # Targets whose most recent assert_element_* check failed. Keyed on the
    # most recent check per target (not "any failure ever") so the legitimate
    # probe pattern — assert, recover, re-assert — is not penalized.
    def failing_assertions
      @assertion_usage.reject { |_target, usage| usage[:last_success] }.keys
    end

    private

    def exec_get_tree
      tree = @wda.get_tree(format: :description)
      raise InfraError, 'Empty accessibility tree — WDA session may have expired' if tree.nil? || tree.empty?

      tree
    end

    def exec_tap(input)
      x, y = input.values_at('x', 'y')
      times = parse_repeat_count(input['times'])

      times.times do |tap_number|
        @wda.tap_at(x, y)
        sleep REPEAT_TAP_INTERVAL_SECONDS if tap_number < times - 1
      end

      @logger.info "  Tapped (#{x}, #{y})#{" #{times} times" if times > 1}"
      return "Tapped at (#{x}, #{y})" if times == 1

      "Tapped at (#{x}, #{y}) #{times} times"
    end

    def exec_tap_element(input)
      identifier = present_string(input['identifier'])
      label = present_string(input['label'])
      times = parse_repeat_count(input['times'])
      element_id = find_element_id(identifier, label)

      if element_id.nil?
        target = identifier || label || '(no identifier or label provided)'
        return "#{ELEMENT_NOT_FOUND_PREFIX} #{target}. #{TAP_BY_COORDINATES_HINT}"
      end

      target = identifier || label
      completed = perform_repeated_taps(element_id, identifier, label, times)
      if completed == 1 && times == 1
        @logger.info "  Tapped element '#{target}'"
      else
        @logger.info "  Tapped element '#{target}' #{completed} of #{times} times"
      end

      return "Tapped element: #{target}" if times == 1 && completed == 1
      return "Tapped element: #{target} #{completed} times" if completed == times

      "Tapped element: #{target} #{completed} of #{times} times — the element became " \
        'unavailable; fetch the accessibility tree to see the current screen.'
    end

    # Tap the element `times` times with a short pause between taps. If a tap
    # fails (typically a stale element reference after the UI re-rendered),
    # re-find the element once and continue; stop early if it is gone for good.
    def perform_repeated_taps(element_id, identifier, label, times)
      completed = 0
      while completed < times
        unless tap_element_once(element_id)
          element_id = find_element_id(identifier, label)
          break if element_id.nil? || !tap_element_once(element_id)
        end
        completed += 1
        sleep REPEAT_TAP_INTERVAL_SECONDS if completed < times
      end
      completed
    end

    # A failed click usually means a stale element reference (recoverable by
    # re-finding); infrastructure failures must keep propagating so the
    # executor's infra-error accounting sees them.
    def tap_element_once(element_id)
      @wda.click_element(element_id)
      true
    rescue InfraError
      raise
    rescue StandardError
      false
    end

    # Shared element lookup: accessibility identifier first, then the label as
    # an identifier, then a name/label predicate match.
    def find_element_id(identifier, label)
      element_id = nil
      element_id = @wda.find_element(using: 'accessibility id', value: identifier) if identifier
      element_id = @wda.find_element(using: 'accessibility id', value: label) if element_id.nil? && label
      element_id = @wda.find_element(using: 'predicate string', value: label_predicate(label)) if element_id.nil? && label
      element_id
    end

    def exec_assert_element(input, expect_present:)
      identifier = present_string(input['identifier'])
      label = present_string(input['label'])
      target = identifier || label
      raise "requires 'identifier' or 'label'" if target.nil?

      element_id = find_element_id(identifier, label)
      found = !element_id.nil?
      # Summarize before recording: an InfraError during the attribute reads
      # aborts the whole tool call, and a call that errored must not record an
      # assertion outcome (it could otherwise mark a previously failing target
      # as satisfied even though the model never saw a successful result).
      state_summary = found ? element_state_summary(element_id) : ''
      record_assertion(target, found == expect_present)
      @logger.info "  Assert #{expect_present ? 'exists' : 'absent'} '#{target}': #{found ? 'found' : 'not found'}"

      if expect_present
        return "Element exists: #{target}#{state_summary}" if found

        "ASSERTION FAILED — element not found: #{target}. If this is unexpected, " \
          'fetch the accessibility tree to see the current screen.'
      elsif found
        "ASSERTION FAILED — element is still present: #{target}#{state_summary}."
      else
        "Element is absent: #{target}"
      end
    end

    # Summarize a found element's state so the one-line result can also answer
    # "what state is it in" (e.g. a switch's value), often saving a follow-up
    # tree fetch. Attribute reads degrade gracefully for element-level failures
    # (e.g. a stale reference) — the summary is just omitted — but infrastructure
    # failures keep propagating so they surface in the infra-error accounting.
    def element_state_summary(element_id)
      parts = ELEMENT_STATE_ATTRIBUTES.filter_map do |name|
        value = begin
          @wda.element_attribute(element_id, name)
        rescue InfraError
          raise
        rescue StandardError
          nil
        end
        "#{name}: #{value}" unless value.nil? || value.to_s.empty?
      end
      parts.empty? ? '' : " (#{parts.join(', ')})"
    end

    # Poll for an element until it appears or the timeout elapses. Returns a
    # one-line result either way, so a screen transition can be awaited without
    # re-reading full accessibility trees.
    def exec_wait_for_element(input)
      identifier = present_string(input['identifier'])
      label = present_string(input['label'])
      target = identifier || label
      raise "requires 'identifier' or 'label'" if target.nil?

      timeout_seconds = clamp_wait_timeout(input['timeout_seconds'])
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = started + timeout_seconds
      loop do
        if (element_id = find_element_id(identifier, label))
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          @logger.info "  Element '#{target}' appeared after #{elapsed.round(1)}s"
          return "Element appeared after #{elapsed.round(1)}s: #{target}#{element_state_summary(element_id)}"
        end

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break unless remaining.positive?

        sleep [remaining, POLL_INTERVAL_SECONDS].min
      end

      "Element did NOT appear within #{timeout_seconds}s: #{target}. " \
        'Fetch the accessibility tree if you need to see the current screen.'
    end

    def exec_tap_collection_cell(input)
      collection = present_string(input['collection_identifier'])
      raise "requires 'collection_identifier'" if collection.nil?

      index = parse_cell_index(input['index'])

      collection_id = @wda.find_element(using: 'accessibility id', value: collection)
      return "#{ELEMENT_NOT_FOUND_PREFIX} #{collection}. #{TAP_BY_COORDINATES_HINT}" if collection_id.nil?

      cells = @wda.find_child_elements(collection_id, using: 'class chain', value: '**/XCUIElementTypeCell')
      if cells.empty?
        return "No cells found inside #{collection}. The collection may still be loading — " \
               'wait briefly and retry, or fetch the accessibility tree.'
      end
      if index >= cells.length
        return "Cell index #{index} is out of range: #{collection} has #{cells.length} " \
               "visible cells (0-#{cells.length - 1})."
      end

      cell = cells[index]
      cell_id = cell['ELEMENT'] || cell.values.first
      @wda.click_element(cell_id)
      @logger.info "  Tapped cell #{index} of '#{collection}'"
      "Tapped cell #{index} of #{collection} (#{cells.length} cells visible)"
    end

    # Reject anything that is not a whole number instead of silently coercing
    # (to_i would turn 1.9 or "1foo" into 1 and tap the wrong cell); a loud
    # error lets the model correct its input.
    def parse_cell_index(value)
      return 0 if value.nil?

      index = parse_whole_number(value)
      raise "index must be a whole number, 0 or greater (got #{value.inspect})" if index.nil? || index.negative?

      index
    end

    def parse_repeat_count(value)
      return 1 if value.nil?

      count = parse_whole_number(value)
      raise "times must be a whole number between 1 and #{MAX_TAP_REPEATS} (got #{value.inspect})" if count.nil? || count < 1 || count > MAX_TAP_REPEATS

      count
    end

    def parse_whole_number(value)
      case value
      when Integer then value
      when Float then ((value % 1).zero? ? value.to_i : nil)
      when String then Integer(value, 10, exception: false)
      end
    end

    # Tap and return the resulting accessibility tree in one tool call, so the
    # common "tap then read the screen" step costs one turn instead of two.
    def exec_tap_and_wait(input)
      raise "tap_and_wait requires 'identifier', 'label', or both 'x' and 'y'" unless present_string(input['identifier']) || present_string(input['label']) || (input['x'] && input['y'])

      previous_tree = present_string(input['wait_for']) ? nil : exec_get_tree
      status, tapped = perform_tap(input)
      tree = if tapped
               settle_and_read_tree(input, previous_tree: previous_tree)
             else
               previous_tree || exec_get_tree
             end

      # If the element wasn't found, the tree is already included below, so point
      # the model at it instead of telling it to fetch the tree (a wasted turn).
      # That hint only works if the tree is actually below — bypass deduplication
      # on a failed tap so the recovery path always has the full tree in hand.
      status = status.sub(TAP_BY_COORDINATES_HINT, 'Find the target in the accessibility tree below and tap by coordinates instead.')
      "#{status}\n\n#{dedupe_tree(tree, force_full: !tapped)}"
    end

    # Replace a tree identical to the one most recently returned to the model
    # with a short marker. Re-sending an unchanged ~25KB tree adds nothing the
    # model doesn't already have, but its tokens are re-billed on every later
    # turn of the conversation; the marker carries the same information ("the
    # screen did not change"). Comparison ignores memory addresses, which differ
    # between snapshots of an otherwise identical UI. Internal tree reads (e.g.
    # the change-polling in settle_and_read_tree) bypass this on purpose — only
    # results that reach the model are deduplicated.
    #
    # force_full returns (and records) the full tree even when unchanged — used
    # on failure paths whose message directs the model at "the tree below".
    def dedupe_tree(tree, force_full: false)
      comparable = comparable_tree(tree)
      return TREE_UNCHANGED_MESSAGE if !force_full && comparable == @last_tree_for_dedupe

      @last_tree_for_dedupe = comparable
      tree
    end

    def perform_tap(input)
      identifier = present_string(input['identifier'])
      label = present_string(input['label'])
      x = input['x']
      y = input['y']

      if identifier || label
        status = exec_tap_element(input)
        return [status, !status.start_with?(ELEMENT_NOT_FOUND_PREFIX)]
      end

      [exec_tap(input), true] if x && y
    end

    # Read the tree once; if a wait_for marker was given, keep re-reading until
    # it appears. Without a marker, briefly wait for the tree to change from the
    # pre-tap state. This keeps tap_and_wait from returning the stale screen that
    # the old tap + next-turn get_accessibility_tree pattern naturally avoided.
    # Uses a monotonic clock and never sleeps past the deadline.
    def settle_and_read_tree(input, previous_tree:)
      marker = present_string(input['wait_for'])
      timeout_seconds = marker ? clamp_wait_timeout(input['timeout_seconds']) : DEFAULT_TREE_CHANGE_TIMEOUT_SECONDS
      previous_comparable_tree = marker || previous_tree.nil? ? nil : comparable_tree(previous_tree)
      tree = exec_get_tree
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      until tree_settled?(tree, marker, previous_comparable_tree)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break unless remaining.positive?

        sleep [remaining, POLL_INTERVAL_SECONDS].min
        tree = exec_get_tree
      end
      tree
    end

    def tree_settled?(tree, marker, previous_comparable_tree)
      marker ? tree.include?(marker) : previous_comparable_tree.nil? || comparable_tree(tree) != previous_comparable_tree
    end

    def comparable_tree(tree)
      tree.gsub(/0x[0-9a-fA-F]+\b/, '0xADDR')
    end

    def clamp_wait_timeout(seconds)
      [[(seconds || 3).to_f, 10].min, 0.5].max
    end

    def exec_swipe(input)
      x1, y1, x2, y2 = input.values_at('x1', 'y1', 'x2', 'y2')
      duration = input['duration'] || 500
      @wda.swipe(x1, y1, x2, y2, duration: duration)
      @logger.info "  Swiped (#{x1},#{y1}) -> (#{x2},#{y2})"
      "Swiped from (#{x1}, #{y1}) to (#{x2}, #{y2})"
    end

    def exec_type_text(input)
      text = input['text']
      @wda.type_text(text)
      @logger.info "  Typed #{text.to_s.length} characters"
      "Typed #{text.to_s.length} characters"
    end

    def exec_clear_text
      @wda.clear_text
      @logger.info '  Cleared text field'
      'Text field cleared'
    end

    def exec_screenshot(input)
      max = @config.max_screenshots_per_test
      if max && @screenshot_count >= max
        @logger.debug "Screenshot skipped (limit of #{max} reached)"
        return "Screenshot limit reached (#{max} per test). Use get_accessibility_tree instead."
      end

      label = input['label'] || 'screenshot'
      @screenshot_count += 1
      safe_label = label.gsub(/[^a-zA-Z0-9_-]/, '_')
      filename = "#{safe_label}-#{@screenshot_count}.png"

      dir = @config.screenshots_dir || '/tmp'
      FileUtils.mkdir_p(dir)
      path = File.join(dir, filename)

      saved_path = @simulator.screenshot(@config.simulator_udid, path)
      @logger.info "  Screenshot: #{saved_path}"
      "Screenshot saved to #{saved_path}"
    end

    def exec_launch_app
      args = {
        'ui-testing' => 'YES',
        'ui-test-reset-everything' => 'YES',
        'ui-test-disable-prompts' => 'YES',
        'ui-test-disable-animations' => 'YES',
        'ui-test-disable-migration' => 'YES',
        'ui-test-site-url' => @config.site_url,
        'ui-test-site-user' => @config.username,
        'ui-test-site-pass' => @config.app_password
      }
      @simulator.launch_app(@config.simulator_udid, @config.app_bundle_id, args: args)
      'App launched with test credentials and UI testing flags (reset state, disabled prompts/animations). ' \
        'Wait 2-3 seconds for it to load.'
    end

    def exec_rest_api(input)
      purpose = input['purpose']
      method = input['method']
      path = input['path']
      body = input['body']
      query = input['query']

      validate_rest_api_purpose!(purpose)
      validate_rest_api_path!(path)
      validate_rest_api_policy!(purpose, method, path)

      uri = URI("#{@config.site_url}#{path}")
      if query
        params = URI.encode_www_form(query)
        uri.query = uri.query ? "#{uri.query}&#{params}" : params
      end

      request = build_http_request(method, uri)
      request['Content-Type'] = 'application/json'
      credentials = Base64.strict_encode64("#{@config.username}:#{@config.app_password}")
      request['Authorization'] = "Basic #{credentials}"
      request.body = JSON.generate(body) if body

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
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
      seconds = [[input['seconds'].to_f, 10].min, 0.1].max
      sleep(seconds)
      "Waited #{seconds} seconds"
    end

    def exec_complete_test(input)
      status = input['status']
      reason = input['reason'].to_s.strip
      raise "complete_test status must be 'pass' or 'fail'" unless %w[pass fail].include?(status)
      raise 'complete_test reason must not be empty' if reason.empty?

      @test_completed = true
      @test_status = status
      @test_reason = reason
      @logger.info "  Test result: #{@test_status.upcase} — #{@test_reason}"
      "Test marked as #{@test_status}: #{@test_reason}"
    end

    def validate_rest_api_purpose!(purpose)
      return if %w[setup verification cleanup].include?(purpose)

      raise "REST API purpose '#{purpose}' is not allowed. " \
            'Use setup, verification, or cleanup.'
    end

    def validate_rest_api_path!(path)
      raise 'REST API path is required' if present_string(path).nil?

      decoded = CGI.unescape(path.to_s)
      raise "REST API path must not contain '..'" if decoded.include?('..')

      allowed = @config.rest_api_allowed_prefix
      return if allowed.nil? || allowed.empty?

      normalized = File.expand_path(decoded, '/')
      normalized_prefix = File.expand_path(allowed, '/')

      return if normalized == normalized_prefix || normalized.start_with?("#{normalized_prefix}/")

      raise "REST API path '#{path}' is not allowed. " \
            "Only paths starting with '#{allowed}' are permitted."
    end

    def validate_rest_api_policy!(purpose, method, path)
      return unless @config.rest_api_policy == 'cleanup-delete-only'

      allowed_methods = CLEANUP_DELETE_ONLY_METHODS.fetch(purpose)
      return if allowed_methods.include?(method)

      raise "REST API policy 'cleanup-delete-only' does not allow #{purpose} #{method} " \
            "requests to '#{path}'. Allowed methods for #{purpose}: #{allowed_methods.join(', ')}."
    end

    def build_http_request(method, uri)
      case method
      when 'GET'    then Net::HTTP::Get.new(uri)
      when 'POST'   then Net::HTTP::Post.new(uri)
      when 'PUT'    then Net::HTTP::Put.new(uri)
      when 'DELETE' then Net::HTTP::Delete.new(uri)
      else raise "Unsupported HTTP method: #{method}"
      end
    end

    def record_assertion(target, satisfied)
      usage = @assertion_usage[target]
      usage[:calls] += 1
      usage[:failures] += 1 unless satisfied
      usage[:last_success] = satisfied
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

    def sanitized_debug_input(input)
      JSON.generate(sanitize_for_log(input))
    end

    def sanitize_for_log(value)
      case value
      when Hash
        value.transform_values { |inner| sanitize_for_log(inner) }
      when Array
        value.map { |inner| sanitize_for_log(inner) }
      when String
        redact_string(value)
      else
        value
      end
    end

    def redact_string(value)
      return value if value.nil?
      return '[REDACTED]' if !@config.app_password.nil? && value.include?(@config.app_password)

      value
    end

    def present_string(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def label_predicate(label)
      return nil if label.nil?

      escaped = label.gsub('\\', '\\\\').gsub('"', '\"')
      %(name == "#{escaped}" OR label == "#{escaped}")
    end
  end
end
