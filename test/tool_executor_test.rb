# frozen_string_literal: true

require_relative "test_helper"

class ToolExecutorTest < Minitest::Test
  def setup
    @config = build_config
    @logger, = build_logger
    @wda = FakeWDA.new
    @simulator = FakeSimulator.new
    @executor = SimPilot::ToolExecutor.new(
      wda: @wda,
      simulator: @simulator,
      config: @config,
      logger: @logger
    )
  end

  def test_launch_app_uses_runner_owned_flags
    @executor.execute("launch_app", {})

    _, _udid, _bundle_id, args = @simulator.calls.last
    assert_equal "YES", args["ui-testing"]
    assert_equal "YES", args["ui-test-reset-everything"]
    assert_equal @config.site_url, args["ui-test-site-url"]
    assert_equal @config.username, args["ui-test-site-user"]
  end

  def test_rest_api_tracks_usage_by_purpose_and_success
    response = fake_response(code: 200, body: '{"id": 101}')
    http = FakeHTTPTransport.new(response: response)

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      result = @executor.execute("rest_api_call", {
        "purpose" => "verification",
        "method" => "GET",
        "path" => "/wp-json/wp/v2/posts"
      })

      assert_includes result, "HTTP 200"
      assert @executor.rest_api_called?("verification")
      assert @executor.rest_api_satisfied?("verification")
    end
  end

  def test_rest_api_rejects_paths_outside_allowed_prefix
    result = @executor.execute("rest_api_call", {
      "purpose" => "cleanup",
      "method" => "DELETE",
      "path" => "/xmlrpc.php"
    })

    assert_match(/\AError:/, result)
    assert @executor.rest_api_called?("cleanup")
    refute @executor.rest_api_satisfied?("cleanup")
  end

  def test_infra_errors_increment_and_reset_consecutive_count
    @wda.tree = nil

    result = @executor.execute("get_accessibility_tree", {})

    assert_match(/\AINFRASTRUCTURE ERROR:/, result)
    assert_equal 1, @executor.total_infra_errors
    assert_equal 1, @executor.consecutive_infra_errors

    @executor.execute("wait", { "seconds" => 0.1 })

    assert_equal 1, @executor.total_infra_errors
    assert_equal 0, @executor.consecutive_infra_errors
  end

  def test_complete_test_sets_terminal_state
    @executor.execute("complete_test", { "status" => "pass", "reason" => "done" })

    assert @executor.test_completed
    assert_equal "pass", @executor.test_status
    assert_equal "done", @executor.test_reason
  end
end
