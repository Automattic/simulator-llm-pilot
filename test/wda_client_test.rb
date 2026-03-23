# frozen_string_literal: true

require_relative "test_helper"

class WDAClientTest < Minitest::Test
  def setup
    @logger, = build_logger
    @client = SimPilot::WDAClient.new(port: 8100, logger: @logger)
  end

  def test_create_session_extracts_session_id
    response = fake_response(code: 200, body: '{"value":{"sessionId":"abc-123"}}')
    http = FakeHTTPTransport.new(response: response)

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      assert_equal "abc-123", @client.create_session
    end
  end

  def test_transport_failures_raise_infra_error
    Net::HTTP.stub(:start, proc { |_host, _port, **_kwargs, &_block| raise Net::ReadTimeout }) do
      assert_raises(SimPilot::InfraError) { @client.create_session }
    end
  end

  def test_invalid_session_errors_raise_infra_error
    @client.instance_variable_set(:@session_id, "abc")
    response = fake_response(code: 404, body: '{"value":{"error":"invalid session id","message":"expired"}}')
    http = FakeHTTPTransport.new(response: response)

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      assert_raises(SimPilot::InfraError) { @client.tap_at(10, 20) }
    end
  end

  def test_non_infra_wda_errors_raise_standard_error
    @client.instance_variable_set(:@session_id, "abc")
    response = fake_response(code: 404, body: '{"value":{"error":"no such element","message":"missing"}}')
    http = FakeHTTPTransport.new(response: response)

    Net::HTTP.stub(:start, proc { |*_args, **_kwargs, &block| block.call(http) }) do
      error = assert_raises(RuntimeError) { @client.tap_at(10, 20) }
      assert_includes error.message, "no such element"
    end
  end

  def test_actions_require_a_session
    assert_raises(SimPilot::InfraError) { @client.tap_at(10, 20) }
  end
end
