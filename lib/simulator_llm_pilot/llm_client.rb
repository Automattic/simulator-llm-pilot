# frozen_string_literal: true

module SimulatorLLMPilot
  # Minimal Anthropic Messages API client with tool use support.
  # Uses only net/http from stdlib — no external dependencies.
  class LLMClient
    ERROR_TYPES = [
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::ETIMEDOUT,
      Net::OpenTimeout,
      Net::ReadTimeout,
      SocketError,
      EOFError
    ].freeze

    API_URL = 'https://api.anthropic.com/v1/messages'
    API_VERSION = '2023-06-01'
    CACHE_CONTROL = { type: 'ephemeral' }.freeze

    # Running token totals across every request this client makes, so the
    # runner can report per-test and per-run usage (and the effect of caching).
    attr_reader :usage_totals

    def initialize(api_key:, model:, logger:)
      @api_key = api_key
      @model = model
      @logger = logger
      @uri = URI(API_URL)
      @usage_totals = Hash.new(0)
    end

    def create_message(system:, messages:, tools:, max_tokens: 4096)
      body = {
        model: @model,
        max_tokens: max_tokens,
        temperature: 0,
        system: cacheable_system(system),
        tools: tools,
        messages: with_conversation_cache_breakpoint(messages)
      }

      request = Net::HTTP::Post.new(@uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = @api_key
      request['anthropic-version'] = API_VERSION
      request.body = JSON.generate(body)

      response = Net::HTTP.start(@uri.hostname, @uri.port, use_ssl: true) do |http|
        http.read_timeout = 180 # LLM responses can take a while
        http.open_timeout = 30
        http.request(request)
      end

      unless response.code.to_i == 200
        error_body = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          response.body
        end
        raise LLMError, "Anthropic API error (HTTP #{response.code}): #{error_body}"
      end

      parsed = JSON.parse(response.body)
      usage = parsed['usage'] || {}
      record_usage(usage)
      @logger.debug "LLM: #{usage['input_tokens']}in/#{usage['output_tokens']}out, " \
                    "cache_write=#{usage['cache_creation_input_tokens']}, " \
                    "cache_read=#{usage['cache_read_input_tokens']}, stop=#{parsed['stop_reason']}"
      parsed
    rescue *ERROR_TYPES => e
      raise LLMError, "Anthropic API request failed: #{e.message}"
    rescue JSON::ParserError => e
      raise LLMError, "Anthropic API returned invalid JSON: #{e.message}"
    end

    private

    # Wrap the system prompt in a structured block with a cache breakpoint.
    # Tools precede the system prompt in the prompt-cache hierarchy, so this
    # one breakpoint caches the tool schemas AND the system prompt — the large
    # static prefix that would otherwise be re-billed at full price on every
    # turn of the agent loop (hundreds of turns per run).
    def cacheable_system(system)
      [{ type: 'text', text: system.to_s, cache_control: CACHE_CONTROL }]
    end

    # Mark the final block of the most recent message so the conversation
    # prefix is read from cache (0.1x) instead of re-billed at full price each
    # turn. We build a shallow copy and never mutate the caller's history,
    # which must stay byte-stable across turns for cache hits to land.
    def with_conversation_cache_breakpoint(messages)
      return messages if messages.empty?

      last = messages[-1]
      marked = last.merge(content: content_with_cache_control(last[:content]))
      messages[0...-1] + [marked]
    end

    def content_with_cache_control(content)
      blocks = content.is_a?(String) ? [{ type: 'text', text: content }] : content.map(&:dup)
      blocks[-1] = blocks[-1].merge(cache_control: CACHE_CONTROL)
      blocks
    end

    def record_usage(usage)
      @usage_totals[:requests] += 1
      @usage_totals[:input_tokens] += usage['input_tokens'].to_i
      @usage_totals[:output_tokens] += usage['output_tokens'].to_i
      @usage_totals[:cache_creation_input_tokens] += usage['cache_creation_input_tokens'].to_i
      @usage_totals[:cache_read_input_tokens] += usage['cache_read_input_tokens'].to_i
    end
  end
end
