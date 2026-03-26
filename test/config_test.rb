# frozen_string_literal: true

require_relative 'test_helper'

class ConfigTest < Minitest::Test
  def test_initialize_loads_environment_defaults
    with_env(
      'ANTHROPIC_API_KEY' => 'key-123',
      'SIMULATOR_LLM_PILOT_SITE_URL' => 'https://wp.test',
      'SIMULATOR_LLM_PILOT_USERNAME' => 'ian',
      'SIMULATOR_LLM_PILOT_APP_PASSWORD' => 'secret'
    ) do
      config = SimulatorLLMPilot::Config.new

      assert_equal 'key-123', config.anthropic_api_key
      assert_equal 'https://wp.test', config.site_url
      assert_equal 'ian', config.username
      assert_equal 'secret', config.app_password
      assert_equal '/wp-json/', config.rest_api_allowed_prefix
      assert_equal 20, config.max_context_turns
    end
  end

  def test_validate_reports_missing_and_invalid_values
    with_env('ANTHROPIC_API_KEY' => nil) do
      config = SimulatorLLMPilot::Config.new
      config.site_url = 'not a url'
      config.rest_api_allowed_prefix = 'wp-json'
      config.wda_port = 0
      config.max_turns_per_test = 0
      config.test_timeout = 0
      config.max_context_turns = -1

      error = assert_raises(ArgumentError) { config.validate! }

      assert_includes error.message, 'ANTHROPIC_API_KEY env var is required'
      assert_includes error.message, '--site-url must be a valid URL'
      assert_includes error.message, '--rest-api-prefix must start with /'
      assert_includes error.message, '--wda-port must be a positive integer'
      assert_includes error.message, '--max-context-turns must be zero or greater'
    end
  end
end
