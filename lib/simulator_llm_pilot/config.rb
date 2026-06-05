# frozen_string_literal: true

module SimulatorLLMPilot
  class Config
    attr_accessor :app_bundle_id, :app_name, :site_url, :username, :app_password,
                  :simulator_udid, :simulator_name,
                  :wda_port, :wda_project_path,
                  :results_dir, :screenshots_dir,
                  :anthropic_api_key, :anthropic_model,
                  :max_turns_per_test, :test_timeout,
                  :max_context_turns, :compress_context_when_chars_exceed,
                  :max_screenshots_per_test,
                  :rest_api_allowed_prefix, :app_instructions

    def initialize
      @wda_port = 8100
      @anthropic_model = 'claude-sonnet-4-6'
      @max_turns_per_test = 100
      @test_timeout = 600 # 10 minutes per test
      @max_context_turns = 20 # when compressing, keep this many recent turns of trees intact
      # Only compress old accessibility trees once the conversation grows past this
      # many characters (~150k tokens). Below it, history stays append-only so prompt
      # caching keeps hitting; above it, compression acts as a context-window safety
      # valve for unusually long tests. See Agent#compress_old_trees!.
      @compress_context_when_chars_exceed = 600_000
      @max_screenshots_per_test = 5
      @rest_api_allowed_prefix = '/wp-json/' # only allow WP REST API paths
      @app_instructions = nil # caller-provided app-specific instructions (login flow, etc.)
      @app_name = nil # optional display name for the app (defaults to bundle ID)
      @anthropic_api_key = ENV.fetch('ANTHROPIC_API_KEY', nil)
      @site_url = ENV.fetch('SIMULATOR_LLM_PILOT_SITE_URL', nil)
      @username = ENV.fetch('SIMULATOR_LLM_PILOT_USERNAME', nil)
      @app_password = ENV.fetch('SIMULATOR_LLM_PILOT_APP_PASSWORD', nil)
    end

    def validate!
      @site_url = normalized_site_url(@site_url)

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
      errors.concat(site_url_errors)
      errors.concat(rest_api_prefix_errors)

      raise ArgumentError, "Configuration errors:\n  #{errors.join("\n  ")}" unless errors.empty?
    end

    private

    def blank?(value)
      value.nil? || value.strip.empty?
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def site_url_errors
      return [] if blank?(@site_url)

      uri = URI.parse(@site_url)
      errors = []
      errors << '--site-url must use http or https' unless uri.is_a?(URI::HTTP)
      errors << '--site-url must include a host' if blank?(uri.host)
      errors
    rescue URI::InvalidURIError
      ['--site-url must be a valid URL']
    end

    def rest_api_prefix_errors
      return [] if @rest_api_allowed_prefix.nil? || @rest_api_allowed_prefix.empty?

      errors = []
      errors << '--rest-api-prefix must start with /' unless @rest_api_allowed_prefix.start_with?('/')
      errors << '--rest-api-prefix must not contain ..' if @rest_api_allowed_prefix.include?('..')
      errors
    end

    def normalized_site_url(value)
      return value if blank?(value)

      uri = URI.parse(value)
      return value if uri.scheme

      "https://#{value}"
    rescue URI::InvalidURIError
      value
    end
  end
end
