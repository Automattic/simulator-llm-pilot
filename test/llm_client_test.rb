# frozen_string_literal: true

require_relative "test_helper"

class LLMClientTest < Minitest::Test
  def setup
    @logger, = build_logger
    @client = SimulatorLLMPilot::LLMClient.new(api_key: "key", model: "claude-test", logger: @logger)
  end

  def test_create_message_sends_deterministic_request_body
    response = fake_response(code: 200, body: '{"content":[],"usage":{"input_tokens":1,"output_tokens":2},"stop_reason":"end_turn"}')
    http = FakeHTTPTransport.new(response: response)

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      @client.create_message(system: "sys", messages: [], tools: [])
    end

    body = JSON.parse(http.requests.first.body)
    assert_equal "claude-test", body["model"]
    assert_equal 0, body["temperature"]
    assert_equal [], body["tools"]
  end

  def test_non_200_responses_raise_llm_error
    response = fake_response(code: 429, body: '{"error":"rate_limited"}')
    http = FakeHTTPTransport.new(response: response)

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      assert_raises(SimulatorLLMPilot::LLMError) do
        @client.create_message(system: "sys", messages: [], tools: [])
      end
    end
  end

  def test_timeout_raises_llm_error
    Net::HTTP.stub(:start, proc { |_host, _port, **_kwargs, &_block| raise Net::ReadTimeout }) do
      assert_raises(SimulatorLLMPilot::LLMError) do
        @client.create_message(system: "sys", messages: [], tools: [])
      end
    end
  end
end
