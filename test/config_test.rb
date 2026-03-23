# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def test_initialize_loads_environment_defaults
    with_env(
      "ANTHROPIC_API_KEY" => "key-123",
      "SIM_PILOT_SITE_URL" => "https://wp.test",
      "SIM_PILOT_USERNAME" => "ian",
      "SIM_PILOT_APP_PASSWORD" => "secret"
    ) do
      config = SimPilot::Config.new

      assert_equal "key-123", config.anthropic_api_key
      assert_equal "https://wp.test", config.site_url
      assert_equal "ian", config.username
      assert_equal "secret", config.app_password
      assert_equal "/wp-json/", config.rest_api_allowed_prefix
      assert_equal 20, config.max_context_turns
    end
  end

  def test_validate_reports_missing_and_invalid_values
    config = SimPilot::Config.new
    config.wda_port = 0
    config.max_turns_per_test = 0
    config.test_timeout = 0
    config.max_context_turns = -1

    error = assert_raises(ArgumentError) { config.validate! }

    assert_includes error.message, "ANTHROPIC_API_KEY env var is required"
    assert_includes error.message, "--wda-port must be a positive integer"
    assert_includes error.message, "--max-context-turns must be zero or greater"
  end
end
