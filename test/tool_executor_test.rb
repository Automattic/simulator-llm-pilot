# frozen_string_literal: true

require_relative 'test_helper'

class ToolExecutorTest < Minitest::Test
  def setup
    @config = build_config
    @logger, = build_logger
    @wda = FakeWDA.new
    @simulator = FakeSimulator.new
    @executor = SimulatorLLMPilot::ToolExecutor.new(
      wda: @wda,
      simulator: @simulator,
      config: @config,
      logger: @logger
    )
  end

  def test_launch_app_uses_runner_owned_flags
    @executor.execute('launch_app', {})

    _, _udid, _bundle_id, args = @simulator.calls.last

    assert_equal 'YES', args['ui-testing']
    assert_equal 'YES', args['ui-test-reset-everything']
    assert_equal @config.site_url, args['ui-test-site-url']
    assert_equal @config.username, args['ui-test-site-user']
  end

  def test_tap_element_uses_predicate_fallback_for_labels
    @wda.set_find_element_result(using: 'accessibility id', value: 'Publish', result: nil)
    @wda.set_find_element_result(
      using: 'predicate string',
      value: 'name == "Publish" OR label == "Publish"',
      result: 'element-123'
    )

    result = @executor.execute('tap_element', { 'label' => 'Publish' })

    assert_equal 'Tapped element: Publish', result
    assert_includes @wda.calls, [:find_element, 'predicate string', 'name == "Publish" OR label == "Publish"']
    assert_includes @wda.calls, [:click_element, 'element-123']
  end

  def test_tap_and_wait_taps_element_and_returns_the_tree
    @wda.set_find_element_result(using: 'accessibility id', value: 'create-post-button', result: 'el-1')
    @wda.tree = "Element subtree:\npost-title-field"

    result = @executor.execute('tap_and_wait', { 'identifier' => 'create-post-button' })

    assert_includes result, 'Tapped element: create-post-button'
    assert_includes result, 'post-title-field'
    assert_includes @wda.calls, [:click_element, 'el-1']
    assert_equal(1, @wda.calls.count { |call| call.first == :get_tree })
  end

  def test_tap_and_wait_supports_coordinates
    @wda.tree = "Element subtree:\nsome-screen"

    result = @executor.execute('tap_and_wait', { 'x' => 100, 'y' => 200 })

    assert_includes result, 'Tapped at (100, 200)'
    assert_includes result, 'some-screen'
    assert_includes @wda.calls, [:tap_at, 100, 200]
  end

  def test_tap_and_wait_returns_as_soon_as_the_marker_is_present
    @wda.set_find_element_result(using: 'accessibility id', value: 'open', result: 'el-9')
    @wda.tree = "Element subtree:\nready-marker visible"

    result = @executor.execute('tap_and_wait', { 'identifier' => 'open', 'wait_for' => 'ready-marker' })

    assert_includes result, 'ready-marker'
    assert_equal(1, @wda.calls.count { |call| call.first == :get_tree })
  end

  def test_tap_and_wait_polls_until_timeout_when_the_marker_never_appears
    @wda.set_find_element_result(using: 'accessibility id', value: 'open', result: 'el-9')
    @wda.tree = "Element subtree:\nno-marker-here"

    result = @executor.execute(
      'tap_and_wait',
      { 'identifier' => 'open', 'wait_for' => 'absent', 'timeout_seconds' => 0.5 }
    )

    assert_includes result, 'no-marker-here'
    assert_operator @wda.calls.count { |call| call.first == :get_tree }, :>=, 2
  end

  def test_tap_and_wait_requires_a_target
    result = @executor.execute('tap_and_wait', {})

    assert_match(/\AError:/, result)
    assert_includes result, "requires 'identifier'"
  end

  def test_tap_and_wait_failure_points_to_the_returned_tree
    @wda.tree = "Element subtree:\ncurrent-screen"
    # find_element returns nil by default, so the element is not found.
    result = @executor.execute('tap_and_wait', { 'identifier' => 'missing-button' })

    assert_includes result, 'Element not found: missing-button'
    assert_includes result, 'current-screen'           # the tree is returned in the same call
    assert_includes result, 'accessibility tree below' # points at that tree...
    refute_includes result, 'get_accessibility_tree'   # ...not a redundant separate call
  end

  def test_rest_api_tracks_usage_by_purpose_and_success
    response = fake_response(code: 200, body: '{"id": 101}')
    http = FakeHTTPTransport.new(response: response)

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      result = @executor.execute('rest_api_call', {
                                   'purpose' => 'verification',
                                   'method' => 'GET',
                                   'path' => '/wp-json/wp/v2/posts'
                                 })

      assert_includes result, 'HTTP 200'
      assert @executor.rest_api_called?('verification')
      assert @executor.rest_api_satisfied?('verification')
    end
  end

  def test_rest_api_rejects_paths_outside_allowed_prefix
    result = @executor.execute('rest_api_call', {
                                 'purpose' => 'cleanup',
                                 'method' => 'DELETE',
                                 'path' => '/xmlrpc.php'
                               })

    assert_match(/\AError:/, result)
    assert @executor.rest_api_called?('cleanup')
    refute @executor.rest_api_satisfied?('cleanup')
  end

  def test_rest_api_rejects_path_traversal
    [
      '/wp-json/../wp-login.php',
      '/wp-json/../../etc/passwd',
      '/wp-json/wp/v2/../../../secret',
      '/wp-json/%2e%2e/wp-login.php',
      '/wp-json/%2E%2E/%2E%2E/etc/passwd',
      '/wp-json/wp/v2/%2e%2e%2f%2e%2e%2fsecret'
    ].each do |path|
      result = @executor.execute('rest_api_call', {
                                   'purpose' => 'setup',
                                   'method' => 'GET',
                                   'path' => path
                                 })

      assert_match(/\AError:.*\.\./, result, "Expected path traversal rejection for: #{path}")
    end
  end

  def test_infra_errors_increment_and_reset_consecutive_count
    @wda.tree = nil

    result = @executor.execute('get_accessibility_tree', {})

    assert_match(/\AINFRASTRUCTURE ERROR:/, result)
    assert_equal 1, @executor.total_infra_errors
    assert_equal 1, @executor.consecutive_infra_errors

    @executor.execute('wait', { 'seconds' => 0.1 })

    assert_equal 1, @executor.total_infra_errors
    assert_equal 0, @executor.consecutive_infra_errors
  end

  def test_complete_test_sets_terminal_state
    @executor.execute('complete_test', { 'status' => 'pass', 'reason' => 'done' })

    assert @executor.test_completed
    assert_equal 'pass', @executor.test_status
    assert_equal 'done', @executor.test_reason
  end

  def test_type_text_result_does_not_echo_sensitive_text
    result = @executor.execute('type_text', { 'text' => @config.app_password })

    refute_includes result, @config.app_password
    assert_equal 'Typed 6 characters', result
  end

  def test_screenshot_uses_configured_directory_and_sanitizes_label
    Dir.mktmpdir do |dir|
      @config.screenshots_dir = File.join(dir, 'screenshots')

      result = @executor.execute('take_screenshot', { 'label' => 'login/error 1' })
      _method, udid, path = @simulator.calls.last

      expected_path = File.join(@config.screenshots_dir, 'login_error_1-1.png')

      assert_equal @config.simulator_udid, udid
      assert_equal expected_path, path
      assert_path_exists @config.screenshots_dir
      assert_includes result, expected_path
    end
  end

  def test_sanitize_for_log_preserves_nil_values
    sanitized = @executor.send(:sanitize_for_log, { 'token' => nil, 'items' => [nil, 'ok'] })

    assert_equal({ 'token' => nil, 'items' => [nil, 'ok'] }, sanitized)
  end

  def test_label_predicate_returns_nil_for_nil_labels
    assert_nil @executor.send(:label_predicate, nil)
  end
end
