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

  def test_concise_verification_tools_are_defined
    names = SimulatorLLMPilot::ToolDefinitions.all.map { |definition| definition[:name] }

    assert_includes names, 'assert_element_exists'
    assert_includes names, 'assert_element_absent'
    assert_includes names, 'wait_for_element'
    assert_includes names, 'tap_collection_cell'
  end

  def test_tap_collection_cell_requires_the_collection_identifier
    tool = SimulatorLLMPilot::ToolDefinitions.all.find { |definition| definition[:name] == 'tap_collection_cell' }

    refute_nil tool
    assert_equal %w[collection_identifier], tool[:input_schema][:required]
  end
end
