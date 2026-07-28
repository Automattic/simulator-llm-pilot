# frozen_string_literal: true

require 'zlib'

module SimulatorLLMPilot
  # Writes one redacted, compressed LLM conversation for a selected test result.
  class TranscriptWriter
    FORMAT_VERSION = 1

    def initialize(config:, logger:)
      @config = config
      @logger = logger
    end

    def write(test_case:, result:, index:, transcript: nil)
      return unless should_write?(result)

      transcript ||= yield if block_given?
      return if transcript.nil?

      directory = File.join(@config.results_dir, 'transcripts')
      FileUtils.mkdir_p(directory)
      path = File.join(directory, transcript_filename(test_case, index))

      payload = {
        format_version: FORMAT_VERSION,
        test: {
          title: test_case.title,
          file: File.basename(test_case.file_path),
          status: result[:status],
          model_status: result[:model_status],
          reason: result[:reason]
        },
        model: @config.anthropic_model,
        conversation: transcript
      }

      Zlib::GzipWriter.open(path) do |gzip|
        gzip.write(JSON.pretty_generate(redact(payload)))
      end
      @logger.info "  Transcript: #{path}"
      path
    rescue StandardError => e
      @logger.warn "  Could not write transcript: #{e.message}"
      nil
    end

    private

    def should_write?(result)
      case @config.transcript_policy
      when 'all' then true
      when 'failures' then result[:status] != 'pass'
      else false
      end
    end

    def transcript_filename(test_case, index)
      slug = test_case.title.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
      format('%<index>02d-%<slug>s.json.gz', index: index + 1, slug: slug.empty? ? 'test' : slug)
    end

    def redact(value)
      case value
      when Hash
        value.to_h do |key, inner|
          redacted_key = key.is_a?(String) ? redact_string(key) : key
          [redacted_key, redact(inner)]
        end
      when Array
        value.map { |inner| redact(inner) }
      when String
        redact_string(value)
      else
        value
      end
    end

    def redact_string(value)
      redactions.reduce(value.dup) do |text, (pattern, replacement)|
        text.gsub(pattern, replacement)
      end
    end

    def redactions
      @redactions ||= begin
        exact_pairs = [
          [@config.anthropic_api_key, '[REDACTED:ANTHROPIC_API_KEY]'],
          [@config.app_password, '[REDACTED:APP_PASSWORD]'],
          [basic_auth_value, '[REDACTED:BASIC_AUTH]'],
          [@config.site_url, '[REDACTED:SITE_URL]']
        ]
        patterns = exact_pairs.reject { |sensitive, _replacement| sensitive.nil? || sensitive.empty? }
                              .uniq { |sensitive, _replacement| sensitive }
                              .sort_by { |sensitive, _replacement| -sensitive.length }
                              .map { |sensitive, replacement| [Regexp.new(Regexp.escape(sensitive)), replacement] }

        host = site_host
        patterns << [Regexp.new(Regexp.escape(host), Regexp::IGNORECASE), '[REDACTED:SITE_HOST]'] unless host.empty?

        username = @config.username.to_s
        unless username.empty?
          escaped = Regexp.escape(username)
          patterns << [
            Regexp.new("(?<![[:alnum:]_.-])#{escaped}(?![[:alnum:]_.-])", Regexp::IGNORECASE),
            '[REDACTED:USERNAME]'
          ]
        end
        patterns
      end
    end

    def basic_auth_value
      return '' if @config.username.to_s.empty? || @config.app_password.to_s.empty?

      Base64.strict_encode64("#{@config.username}:#{@config.app_password}")
    end

    def site_host
      URI.parse(@config.site_url).host.to_s
    rescue URI::InvalidURIError
      ''
    end
  end
end
