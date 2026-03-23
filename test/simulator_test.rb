# frozen_string_literal: true

require_relative 'test_helper'

class SimulatorTest < Minitest::Test
  def setup
    @logger, = build_logger
    @simulator = SimulatorLLMPilot::Simulator.new(logger: @logger)
  end

  def test_booted_device_parses_json_output
    output = {
      'devices' => {
        'com.apple.CoreSimulator.SimRuntime.iOS-18-0' => [
          { 'udid' => 'SIM-1', 'name' => 'iPhone 16', 'state' => 'Booted' }
        ]
      }
    }.to_json

    Open3.stub(:capture2, ["#{output}\n", fake_status(true)]) do
      assert_equal({ udid: 'SIM-1', name: 'iPhone 16' }, @simulator.booted_device)
    end
  end

  def test_launch_app_raises_infra_error_on_failure
    Open3.stub(:capture3, ['', 'launch failed', fake_status(false)]) do
      assert_raises(SimulatorLLMPilot::InfraError) do
        @simulator.launch_app('SIM-1', 'org.wordpress', args: {})
      end
    end
  end
end
