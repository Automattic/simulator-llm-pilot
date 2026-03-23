# frozen_string_literal: true

module SimPilot
  # Minimal Anthropic Messages API client with tool use support.
  # Uses only net/http from stdlib — no external dependencies.
  class LLMClient
    API_URL = "https://api.anthropic.com/v1/messages"
    API_VERSION = "2023-06-01"

    def initialize(api_key:, model:, logger:)
      @api_key = api_key
      @model = model
      @logger = logger
      @uri = URI(API_URL)
    end

    def create_message(system:, messages:, tools:, max_tokens: 4096)
      body = {
        model: @model,
        max_tokens: max_tokens,
        system: system,
        tools: tools,
        messages: messages
      }

      request = Net::HTTP::Post.new(@uri)
      request["Content-Type"] = "application/json"
      request["x-api-key"] = @api_key
      request["anthropic-version"] = API_VERSION
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
        raise "Anthropic API error (HTTP #{response.code}): #{error_body}"
      end

      parsed = JSON.parse(response.body)
      usage = parsed["usage"] || {}
      @logger.debug "LLM: #{usage["input_tokens"]}in/#{usage["output_tokens"]}out, " \
                    "stop=#{parsed["stop_reason"]}"
      parsed
    end
  end
end
