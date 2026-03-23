# frozen_string_literal: true

module SimulatorLLMPilot
  class Config
    attr_accessor :app_bundle_id, :site_url, :username, :app_password,
                  :simulator_udid, :simulator_name,
                  :wda_port, :wda_project_path,
                  :results_dir, :screenshots_dir,
                  :anthropic_api_key, :anthropic_model,
                  :max_turns_per_test, :test_timeout,
                  :max_context_turns, :rest_api_allowed_prefix

    def initialize
      @wda_port = 8100
      @anthropic_model = 'claude-sonnet-4-20250514'
      @max_turns_per_test = 100
      @test_timeout = 600 # 10 minutes per test
      @max_context_turns = 20 # compress accessibility trees older than this many turns
      @rest_api_allowed_prefix = '/wp-json/' # only allow WP REST API paths
      @anthropic_api_key = ENV.fetch('ANTHROPIC_API_KEY', nil)
      @site_url = ENV.fetch('SIMULATOR_LLM_PILOT_SITE_URL', nil)
      @username = ENV.fetch('SIMULATOR_LLM_PILOT_USERNAME', nil)
      @app_password = ENV.fetch('SIMULATOR_LLM_PILOT_APP_PASSWORD', nil)
    end

    def validate!
      errors = []
      errors << 'ANTHROPIC_API_KEY env var is required' if blank?(@anthropic_api_key)
      errors << '--app-bundle-id is required' if blank?(@app_bundle_id)
      errors << '--site-url is required (or set SIMULATOR_LLM_PILOT_SITE_URL)' if blank?(@site_url)
      errors << '--username is required (or set SIMULATOR_LLM_PILOT_USERNAME)' if blank?(@username)
      errors << '--app-password is required (or set SIMULATOR_LLM_PILOT_APP_PASSWORD)' if blank?(@app_password)
      errors << '--wda-port must be a positive integer' unless positive_integer?(@wda_port)
      errors << '--max-turns must be a positive integer' unless positive_integer?(@max_turns_per_test)
      errors << '--timeout must be a positive integer' unless positive_integer?(@test_timeout)
      errors << '--max-context-turns must be zero or greater' if @max_context_turns.nil? || @max_context_turns.negative?

      raise ArgumentError, "Configuration errors:\n  #{errors.join("\n  ")}" unless errors.empty?
    end

    private

    def blank?(value)
      value.nil? || value.strip.empty?
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end
  end
end
