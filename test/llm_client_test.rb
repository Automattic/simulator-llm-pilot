# frozen_string_literal: true

require_relative 'test_helper'

class LLMClientTest < Minitest::Test
  def setup
    @logger, = build_logger
    @client = SimulatorLLMPilot::LLMClient.new(api_key: 'key', model: 'claude-test', logger: @logger)
  end

  def test_create_message_sends_deterministic_request_body
    response = fake_response(code: 200, body: '{"content":[],"usage":{"input_tokens":1,"output_tokens":2},"stop_reason":"end_turn"}')
    http = FakeHTTPTransport.new(response: response)

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      @client.create_message(system: 'sys', messages: [], tools: [])
    end

    body = JSON.parse(http.requests.first.body)

    assert_equal 'claude-test', body['model']
    assert_equal 0, body['temperature']
    assert_equal [], body['tools']
  end

  def test_caches_the_system_prompt_and_latest_message
    response = fake_response(code: 200, body: '{"content":[],"usage":{"input_tokens":1,"output_tokens":2}}')
    http = FakeHTTPTransport.new(response: response)

    messages = [
      { role: 'user', content: 'first' },
      { role: 'assistant', content: [{ 'type' => 'text', 'text' => 'ok' }] },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'tree' }] }
    ]

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      @client.create_message(system: 'sys', messages: messages, tools: [])
    end

    body = JSON.parse(http.requests.first.body)

    # System prompt is sent as a cached block (this also caches tools, which
    # precede the system prompt in the prompt-cache hierarchy).
    assert_equal 'sys', body['system'][0]['text']
    assert_equal({ 'type' => 'ephemeral' }, body['system'][0]['cache_control'])

    # Only the final block of the most recent message carries a breakpoint.
    last_message = body['messages'].last

    assert_equal({ 'type' => 'ephemeral' }, last_message['content'][0]['cache_control'])
    refute body['messages'].first.key?('cache_control')
  end

  def test_does_not_mutate_caller_messages
    response = fake_response(code: 200, body: '{"content":[],"usage":{"input_tokens":1,"output_tokens":2}}')
    http = FakeHTTPTransport.new(response: response)
    messages = [{ role: 'user', content: 'only' }]

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      @client.create_message(system: 'sys', messages: messages, tools: [])
    end

    # The stored history must stay byte-stable across turns for cache hits.
    assert_equal([{ role: 'user', content: 'only' }], messages)
  end

  def test_accumulates_token_usage_including_cache_fields
    body = '{"content":[],"usage":{"input_tokens":10,"output_tokens":3,' \
           '"cache_creation_input_tokens":7,"cache_read_input_tokens":40}}'
    http = FakeHTTPTransport.new(response: fake_response(code: 200, body: body))

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      2.times { @client.create_message(system: 'sys', messages: [], tools: []) }
    end

    assert_equal 2, @client.usage_totals[:requests]
    assert_equal 20, @client.usage_totals[:input_tokens]
    assert_equal 6, @client.usage_totals[:output_tokens]
    assert_equal 14, @client.usage_totals[:cache_creation_input_tokens]
    assert_equal 80, @client.usage_totals[:cache_read_input_tokens]
  end

  def test_non_200_responses_raise_llm_error
    response = fake_response(code: 429, body: '{"error":"rate_limited"}')
    http = FakeHTTPTransport.new(response: response)

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      assert_raises(SimulatorLLMPilot::LLMError) do
        @client.create_message(system: 'sys', messages: [], tools: [])
      end
    end
  end

  def test_timeout_raises_llm_error
    Net::HTTP.stub(:start, proc { |_host, _port, **_kwargs, &_block| raise Net::ReadTimeout }) do
      assert_raises(SimulatorLLMPilot::LLMError) do
        @client.create_message(system: 'sys', messages: [], tools: [])
      end
    end
  end
end
