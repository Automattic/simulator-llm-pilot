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

  def test_booted_device_can_select_by_name
    output = {
      'devices' => {
        'com.apple.CoreSimulator.SimRuntime.iOS-18-0' => [
          { 'udid' => 'SIM-1', 'name' => 'iPhone 15', 'state' => 'Booted' },
          { 'udid' => 'SIM-2', 'name' => 'iPhone 16', 'state' => 'Booted' }
        ]
      }
    }.to_json

    Open3.stub(:capture2, ["#{output}\n", fake_status(true)]) do
      assert_equal({ udid: 'SIM-2', name: 'iPhone 16' }, @simulator.booted_device(name: 'iPhone 16'))
    end
  end

  def test_launch_app_raises_infra_error_on_failure
    Open3.stub(:capture3, ['', 'launch failed', fake_status(false)]) do
      assert_raises(SimulatorLLMPilot::InfraError) do
        @simulator.launch_app('SIM-1', 'org.wordpress', args: {})
      end
    end
  end

  def test_screenshot_creates_parent_directory_before_running_simctl
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'nested', 'login_error-1.png')
      calls = []

      Open3.stub(:capture3, proc do |*args|
        calls << args
        ['', '', fake_status(true)]
      end) do
        assert_equal path, @simulator.screenshot('SIM-1', path)
      end

      assert_path_exists File.dirname(path)
      assert_equal ['xcrun', 'simctl', 'io', 'SIM-1', 'screenshot', path], calls.first
    end
  end
end
