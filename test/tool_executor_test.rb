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

  def test_tap_and_wait_taps_element_and_returns_the_changed_tree
    @wda.set_find_element_result(using: 'accessibility id', value: 'create-post-button', result: 'el-1')
    use_tree_sequence(
      "Element subtree:\nold-screen",
      "Element subtree:\npost-title-field"
    )

    result = @executor.execute('tap_and_wait', { 'identifier' => 'create-post-button' })

    assert_includes result, 'Tapped element: create-post-button'
    assert_includes result, 'post-title-field'
    refute_includes result, 'old-screen'
    assert_includes @wda.calls, [:click_element, 'el-1']
    assert_equal(2, @wda.calls.count { |call| call.first == :get_tree })
  end

  def test_tap_and_wait_supports_coordinates
    use_tree_sequence(
      "Element subtree:\nold-screen",
      "Element subtree:\nsome-screen"
    )

    result = @executor.execute('tap_and_wait', { 'x' => 100, 'y' => 200 })

    assert_includes result, 'Tapped at (100, 200)'
    assert_includes result, 'some-screen'
    assert_includes @wda.calls, [:tap_at, 100, 200]
  end

  def test_tap_and_wait_without_marker_polls_until_tree_changes
    @wda.set_find_element_result(using: 'accessibility id', value: 'open', result: 'el-9')
    use_tree_sequence(
      "Element subtree:\nButton, 0x111111, {{0, 0}, {10, 10}}, label: 'Open'",
      "Element subtree:\nButton, 0x222222, {{0, 0}, {10, 10}}, label: 'Open'",
      "Element subtree:\nStaticText, 0x333333, {{0, 0}, {10, 10}}, label: 'Done'"
    )

    result = @executor.execute('tap_and_wait', { 'identifier' => 'open' })

    assert_includes result, "label: 'Done'"
    assert_equal(3, @wda.calls.count { |call| call.first == :get_tree })
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

  def test_get_accessibility_tree_dedupes_unchanged_trees
    @wda.tree = "Element subtree:\nButton, 0x111111, label: 'Open'"
    first = @executor.execute('get_accessibility_tree', {})

    # Same UI, fresh snapshot — only the memory addresses differ.
    @wda.tree = "Element subtree:\nButton, 0x222222, label: 'Open'"
    second = @executor.execute('get_accessibility_tree', {})

    assert_includes first, "label: 'Open'"
    assert_equal SimulatorLLMPilot::ToolExecutor::TREE_UNCHANGED_MESSAGE, second
  end

  def test_get_accessibility_tree_returns_changed_trees_in_full
    @wda.tree = "Element subtree:\nscreen-one"
    @executor.execute('get_accessibility_tree', {})

    @wda.tree = "Element subtree:\nscreen-two"
    result = @executor.execute('get_accessibility_tree', {})

    assert_includes result, 'screen-two'
  end

  def test_tap_and_wait_dedupes_when_the_screen_did_not_change
    @wda.set_find_element_result(using: 'accessibility id', value: 'noop', result: 'el-1')
    @wda.tree = "Element subtree:\nstatic-screen"
    @executor.execute('get_accessibility_tree', {})

    result = @executor.execute('tap_and_wait', { 'identifier' => 'noop' })

    assert_includes result, 'Tapped element: noop'
    assert_includes result, 'unchanged'
    refute_includes result, 'static-screen'
  end

  def test_assert_element_exists_returns_a_one_line_result
    @wda.set_find_element_result(using: 'accessibility id', value: 'imageOptimizationSwitch', result: 'el-5')

    result = @executor.execute('assert_element_exists', { 'identifier' => 'imageOptimizationSwitch' })

    assert_equal 'Element exists: imageOptimizationSwitch', result
  end

  def test_assert_element_exists_summarizes_the_element_state
    @wda.set_find_element_result(using: 'accessibility id', value: 'imageOptimizationSwitch', result: 'el-5')
    @wda.set_element_attributes('el-5', {
                                  'type' => 'Switch', 'label' => 'Optimize Images', 'value' => '1', 'enabled' => true
                                })

    result = @executor.execute('assert_element_exists', { 'identifier' => 'imageOptimizationSwitch' })

    assert_equal 'Element exists: imageOptimizationSwitch ' \
                 '(type: Switch, label: Optimize Images, value: 1, enabled: true)', result
  end

  def test_element_state_summary_degrades_gracefully_when_attributes_fail
    @wda.set_find_element_result(using: 'accessibility id', value: 'save_button', result: 'el-9')
    @wda.fail_on(:element_attribute, RuntimeError.new('stale element'))

    result = @executor.execute('assert_element_exists', { 'identifier' => 'save_button' })

    assert_equal 'Element exists: save_button', result
  end

  def test_wait_for_element_includes_the_element_state
    @wda.set_find_element_result(using: 'accessibility id', value: 'publish_button', result: 'el-3')
    @wda.set_element_attributes('el-3', { 'type' => 'Button', 'enabled' => false })

    result = @executor.execute('wait_for_element', { 'identifier' => 'publish_button' })

    assert_includes result, 'Element appeared'
    assert_includes result, '(type: Button, enabled: false)'
  end

  def test_tap_element_taps_repeatedly_with_the_times_parameter
    @wda.set_find_element_result(using: 'accessibility id', value: 'editor-undo', result: 'el-8')

    result = @executor.execute('tap_element', { 'identifier' => 'editor-undo', 'times' => 3 })

    assert_equal 'Tapped element: editor-undo 3 times', result
    assert_equal(3, @wda.calls.count { |call| call == [:click_element, 'el-8'] })
  end

  def test_tap_element_reports_partial_progress_when_the_element_disappears
    @wda.set_find_element_result(using: 'accessibility id', value: 'editor-undo', result: 'el-8')
    @wda.fail_on(:click_element, RuntimeError.new('stale element reference'))

    result = @executor.execute('tap_element', { 'identifier' => 'editor-undo', 'times' => 3 })

    assert_includes result, '0 of 3 times'
    assert_includes result, 'unavailable'
  end

  def test_tap_element_rejects_a_fractional_times_value
    result = @executor.execute('tap_element', { 'identifier' => 'editor-undo', 'times' => 1.5 })

    assert_match(/\AError:/, result)
    assert_includes result, 'whole number'
  end

  def test_tap_taps_repeatedly_with_the_times_parameter
    result = @executor.execute('tap', { 'x' => 100, 'y' => 200, 'times' => 3 })

    assert_equal 'Tapped at (100, 200) 3 times', result
    assert_equal(3, @wda.calls.count { |call| call == [:tap_at, 100, 200] })
  end

  def test_assert_element_exists_reports_a_missing_element
    result = @executor.execute('assert_element_exists', { 'identifier' => 'missing' })

    assert_includes result, 'ASSERTION FAILED'
    assert_includes result, 'missing'
  end

  def test_assert_element_absent_passes_when_the_element_is_gone
    result = @executor.execute('assert_element_absent', { 'identifier' => 'featured_image_menu' })

    assert_equal 'Element is absent: featured_image_menu', result
  end

  def test_assert_element_absent_fails_when_the_element_is_present
    @wda.set_find_element_result(using: 'accessibility id', value: 'still-here', result: 'el-2')

    result = @executor.execute('assert_element_absent', { 'identifier' => 'still-here' })

    assert_includes result, 'ASSERTION FAILED'
    assert_includes result, 'still present'
  end

  def test_assert_element_requires_a_target
    result = @executor.execute('assert_element_exists', {})

    assert_match(/\AError:/, result)
  end

  def test_wait_for_element_returns_once_the_element_appears
    attempts = 0
    @wda.define_singleton_method(:find_element) do |using:, value:|
      @calls << [:find_element, using, value]
      attempts += 1
      attempts >= 3 ? 'el-7' : nil
    end

    result = @executor.execute('wait_for_element', { 'identifier' => 'late-element' })

    assert_includes result, 'Element appeared'
    assert_includes result, 'late-element'
  end

  def test_wait_for_element_reports_a_timeout
    result = @executor.execute('wait_for_element', { 'identifier' => 'never', 'timeout_seconds' => 0.5 })

    assert_includes result, 'did NOT appear'
    assert_includes result, 'never'
  end

  def test_tap_collection_cell_taps_the_requested_cell
    @wda.set_find_element_result(using: 'accessibility id', value: 'MediaCollection', result: 'collection-1')
    @wda.set_child_elements('collection-1', [
                              { 'ELEMENT' => 'cell-0' }, { 'ELEMENT' => 'cell-1' }, { 'ELEMENT' => 'cell-2' }
                            ])

    result = @executor.execute('tap_collection_cell', { 'collection_identifier' => 'MediaCollection', 'index' => 1 })

    assert_equal 'Tapped cell 1 of MediaCollection (3 cells visible)', result
    assert_includes @wda.calls, [:click_element, 'cell-1']
  end

  def test_tap_collection_cell_defaults_to_the_first_cell
    @wda.set_find_element_result(using: 'accessibility id', value: 'MediaCollection', result: 'collection-1')
    @wda.set_child_elements('collection-1', [{ 'ELEMENT' => 'cell-0' }, { 'ELEMENT' => 'cell-1' }])

    @executor.execute('tap_collection_cell', { 'collection_identifier' => 'MediaCollection' })

    assert_includes @wda.calls, [:click_element, 'cell-0']
  end

  def test_tap_collection_cell_reports_a_missing_collection
    result = @executor.execute('tap_collection_cell', { 'collection_identifier' => 'NoSuchCollection' })

    assert_includes result, 'Element not found: NoSuchCollection'
  end

  def test_tap_collection_cell_reports_an_empty_collection
    @wda.set_find_element_result(using: 'accessibility id', value: 'EmptyCollection', result: 'collection-2')

    result = @executor.execute('tap_collection_cell', { 'collection_identifier' => 'EmptyCollection' })

    assert_includes result, 'No cells found'
  end

  def test_tap_collection_cell_reports_an_out_of_range_index
    @wda.set_find_element_result(using: 'accessibility id', value: 'MediaCollection', result: 'collection-1')
    @wda.set_child_elements('collection-1', [{ 'ELEMENT' => 'cell-0' }, { 'ELEMENT' => 'cell-1' }])

    result = @executor.execute('tap_collection_cell', { 'collection_identifier' => 'MediaCollection', 'index' => 5 })

    assert_includes result, 'out of range'
    assert_includes result, '2 visible cells'
  end

  def test_tap_collection_cell_rejects_a_fractional_index
    result = @executor.execute('tap_collection_cell', { 'collection_identifier' => 'MediaCollection', 'index' => 1.9 })

    assert_match(/\AError:/, result)
    assert_includes result, 'whole number'
  end

  def test_tap_collection_cell_rejects_a_non_numeric_index
    result = @executor.execute('tap_collection_cell',
                               { 'collection_identifier' => 'MediaCollection', 'index' => '1foo' })

    assert_match(/\AError:/, result)
    assert_includes result, 'whole number'
  end

  def test_tap_collection_cell_accepts_integer_like_indices
    @wda.set_find_element_result(using: 'accessibility id', value: 'MediaCollection', result: 'collection-1')
    @wda.set_child_elements('collection-1', [{ 'ELEMENT' => 'cell-0' }, { 'ELEMENT' => 'cell-1' }])

    @executor.execute('tap_collection_cell', { 'collection_identifier' => 'MediaCollection', 'index' => '1' })
    @executor.execute('tap_collection_cell', { 'collection_identifier' => 'MediaCollection', 'index' => 1.0 })

    assert_equal(2, @wda.calls.count { |call| call == [:click_element, 'cell-1'] })
  end

  def test_tap_and_wait_failure_bypasses_tree_dedupe
    @wda.tree = "Element subtree:\nsame-screen"
    @executor.execute('get_accessibility_tree', {})

    # find_element returns nil by default, so the tap target is missing and the
    # failure message points the model at "the accessibility tree below" — the
    # tree must therefore be present in full, not replaced by the marker.
    result = @executor.execute('tap_and_wait', { 'identifier' => 'missing-button' })

    assert_includes result, 'Element not found: missing-button'
    assert_includes result, 'same-screen'
    refute_includes result, 'unchanged'
  end

  def test_failing_assertions_reflects_the_most_recent_result_per_target
    result = @executor.execute('assert_element_exists', { 'identifier' => 'save_button' })

    assert_includes result, 'ASSERTION FAILED'
    assert_equal ['save_button'], @executor.failing_assertions

    # The element appears (e.g. after scrolling); a re-run clears the failure.
    @wda.set_find_element_result(using: 'accessibility id', value: 'save_button', result: 'el-1')
    @executor.execute('assert_element_exists', { 'identifier' => 'save_button' })

    assert_empty @executor.failing_assertions
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

  private

  def use_tree_sequence(*trees)
    sequence = trees.dup
    fallback = trees.last
    @wda.define_singleton_method(:get_tree) do |format:|
      @calls << [:get_tree, format]
      sequence.empty? ? fallback : sequence.shift
    end
  end
end
