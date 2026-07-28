# frozen_string_literal: true

require_relative 'test_helper'

class ConfigTest < Minitest::Test
  def test_initialize_loads_environment_defaults
    with_env(
      'ANTHROPIC_API_KEY' => 'key-123',
      'SIMULATOR_LLM_PILOT_SITE_URL' => 'https://wp.test',
      'SIMULATOR_LLM_PILOT_USERNAME' => 'ian',
      'SIMULATOR_LLM_PILOT_APP_PASSWORD' => 'secret',
      'SIMULATOR_LLM_PILOT_TRANSCRIPT_POLICY' => 'failures'
    ) do
      config = SimulatorLLMPilot::Config.new

      assert_equal 'key-123', config.anthropic_api_key
      assert_equal 'https://wp.test', config.site_url
      assert_equal 'ian', config.username
      assert_equal 'secret', config.app_password
      assert_equal '/wp-json/', config.rest_api_allowed_prefix
      assert_nil config.rest_api_policy
      assert_equal 20, config.max_context_turns
      assert_equal 'failures', config.transcript_policy
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

  def test_validate_normalizes_site_url_without_scheme
    config = SimulatorLLMPilot::Config.new
    config.anthropic_api_key = 'key-123'
    config.app_bundle_id = 'org.wordpress'
    config.site_url = 'wp.test'
    config.username = 'ian'
    config.app_password = 'secret'

    config.validate!

    assert_equal 'https://wp.test', config.site_url
  end

  def test_validate_normalizes_zero_compression_threshold_to_nil
    # 0 means "disable compression" from any entry point, not just the CLI.
    config = build_config
    config.compress_context_when_chars_exceed = 0

    config.validate!

    assert_nil config.compress_context_when_chars_exceed
  end

  def test_validate_rejects_a_negative_compression_threshold
    config = build_config
    config.compress_context_when_chars_exceed = -1

    error = assert_raises(ArgumentError) { config.validate! }

    assert_includes error.message, '--compress-context-over must be a positive integer'
  end

  def test_validate_accepts_the_verification_readonly_rest_api_policy
    config = build_config
    config.rest_api_policy = 'verification-readonly'

    config.validate!
  end

  def test_validate_rejects_an_unknown_rest_api_policy
    config = build_config
    config.rest_api_policy = 'allow-everything'

    error = assert_raises(ArgumentError) { config.validate! }

    assert_includes error.message, '--rest-api-policy must be one of: verification-readonly'
  end

  def test_validate_rejects_an_unknown_transcript_policy
    config = build_config
    config.transcript_policy = 'sometimes'

    error = assert_raises(ArgumentError) { config.validate! }

    assert_includes error.message, '--transcript-policy must be one of: none, failures, all'
  end
end
