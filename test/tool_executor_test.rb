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
      using: '-ios predicate string',
      value: 'name == "Publish" OR label == "Publish"',
      result: 'element-123'
    )

    result = @executor.execute('tap_element', { 'label' => 'Publish' })

    assert_equal 'Tapped element: Publish', result
    assert_includes @wda.calls, [:find_element, '-ios predicate string', 'name == "Publish" OR label == "Publish"']
    assert_includes @wda.calls, [:click_element, 'element-123']
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

  def test_sanitize_for_log_preserves_nil_values
    sanitized = @executor.send(:sanitize_for_log, { 'token' => nil, 'items' => [nil, 'ok'] })

    assert_equal({ 'token' => nil, 'items' => [nil, 'ok'] }, sanitized)
  end

  def test_label_predicate_returns_nil_for_nil_labels
    assert_nil @executor.send(:label_predicate, nil)
  end
end
