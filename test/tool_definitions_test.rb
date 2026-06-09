# frozen_string_literal: true

require_relative 'test_helper'

class ToolDefinitionsTest < Minitest::Test
  def test_rest_api_tool_requires_purpose
    tool = SimulatorLLMPilot::ToolDefinitions.all.find { |definition| definition[:name] == 'rest_api_call' }

    refute_nil tool
    assert_includes tool[:input_schema][:required], 'purpose'
    assert_equal %w[setup verification cleanup], tool[:input_schema][:properties][:purpose][:enum]
  end

  def test_tap_and_wait_tool_is_defined_with_optional_inputs
    tool = SimulatorLLMPilot::ToolDefinitions.all.find { |definition| definition[:name] == 'tap_and_wait' }

    refute_nil tool
    assert_equal [], tool[:input_schema][:required]
    assert tool[:input_schema][:properties].key?(:wait_for)
  end
end
