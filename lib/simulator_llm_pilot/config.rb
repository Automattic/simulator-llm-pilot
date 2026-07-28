# frozen_string_literal: true

module SimulatorLLMPilot
  class Config
    REST_API_POLICIES = %w[verification-readonly].freeze
    TRANSCRIPT_POLICIES = %w[none failures all].freeze

    attr_accessor :app_bundle_id, :app_name, :site_url, :username, :app_password,
                  :simulator_udid, :simulator_name,
                  :wda_port, :wda_project_path,
                  :results_dir, :screenshots_dir,
                  :anthropic_api_key, :anthropic_model,
                  :max_turns_per_test, :test_timeout,
                  :max_context_turns, :compress_context_when_chars_exceed,
                  :max_screenshots_per_test,
                  :rest_api_allowed_prefix, :rest_api_policy, :app_instructions,
                  :transcript_policy

    def initialize
      @wda_port = 8100
      @anthropic_model = 'claude-sonnet-4-6'
      @max_turns_per_test = 100
      @test_timeout = 600 # 10 minutes per test
      @max_context_turns = 20 # when compressing, keep this many recent turns of trees intact
      # Only compress old accessibility trees once the conversation grows past this
      # many characters (~625k tokens — comfortably inside the 1M-token context
      # window of current models). Below it, history stays append-only so prompt
      # caching keeps hitting; above it, compression acts as a context-window safety
      # valve for unusually long tests. Compression rewrites history, which
      # invalidates the cached prompt prefix, so this must stay high enough that
      # normal tests never trigger it. See Agent#compress_old_trees!.
      @compress_context_when_chars_exceed = 2_500_000
      @max_screenshots_per_test = 5
      @rest_api_allowed_prefix = '/wp-json/' # only allow WP REST API paths
      @rest_api_policy = nil
      @transcript_policy = ENV.fetch('SIMULATOR_LLM_PILOT_TRANSCRIPT_POLICY', 'none')
      @app_instructions = nil # caller-provided app-specific instructions (login flow, etc.)
      @app_name = nil # optional display name for the app (defaults to bundle ID)
      @anthropic_api_key = ENV.fetch('ANTHROPIC_API_KEY', nil)
      @site_url = ENV.fetch('SIMULATOR_LLM_PILOT_SITE_URL', nil)
      @username = ENV.fetch('SIMULATOR_LLM_PILOT_USERNAME', nil)
      @app_password = ENV.fetch('SIMULATOR_LLM_PILOT_APP_PASSWORD', nil)
    end

    def validate!
      @site_url = normalized_site_url(@site_url)
      # 0 means "disable compression" regardless of how the value was set (CLI
      # or programmatically); nil is the canonical disabled state everywhere else.
      @compress_context_when_chars_exceed = nil if @compress_context_when_chars_exceed.is_a?(Numeric) && @compress_context_when_chars_exceed.zero?

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
      errors << '--compress-context-over must be a positive integer (or 0 to disable)' unless valid_compression_threshold?
      errors.concat(site_url_errors)
      errors.concat(rest_api_prefix_errors)
      errors.concat(rest_api_policy_errors)
      errors.concat(transcript_policy_errors)

      raise ArgumentError, "Configuration errors:\n  #{errors.join("\n  ")}" unless errors.empty?
    end

    private

    def blank?(value)
      value.nil? || value.strip.empty?
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def valid_compression_threshold?
      @compress_context_when_chars_exceed.nil? || positive_integer?(@compress_context_when_chars_exceed)
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

    def rest_api_policy_errors
      return [] if @rest_api_policy.nil? || REST_API_POLICIES.include?(@rest_api_policy)

      ["--rest-api-policy must be one of: #{REST_API_POLICIES.join(', ')}"]
    end

    def transcript_policy_errors
      return [] if TRANSCRIPT_POLICIES.include?(@transcript_policy)

      ["--transcript-policy must be one of: #{TRANSCRIPT_POLICIES.join(', ')}"]
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
