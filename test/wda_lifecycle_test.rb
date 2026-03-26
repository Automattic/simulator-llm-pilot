# frozen_string_literal: true

require_relative 'test_helper'

class WDALifecycleTest < Minitest::Test
  def setup
    @logger, = build_logger
    @lifecycle = SimulatorLLMPilot::WDALifecycle.new(port: 9010, logger: @logger)
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_start_reuses_own_running_process
    @lifecycle.stub(:running?, true) do
      @lifecycle.stub(:own_process_running?, true) do
        assert @lifecycle.start(udid: 'SIM-1', wda_project_path: '/tmp/ignored', wda_derived_data_path: '/tmp/DerivedData')
      end
    end
  end

  def test_start_raises_when_port_is_owned_by_another_process
    @lifecycle.stub(:running?, true) do
      @lifecycle.stub(:own_process_running?, false) do
        error = assert_raises(RuntimeError) do
          @lifecycle.start(udid: 'SIM-1', wda_project_path: '/tmp/ignored', wda_derived_data_path: '/tmp/DerivedData')
        end

        assert_includes error.message, 'already in use'
      end
    end
  end

  def test_stop_only_kills_scoped_pid
    pid_path = File.join(@dir, 'wda.pid')
    log_path = File.join(@dir, 'wda.log')
    File.write(pid_path, '1234')
    @lifecycle.instance_variable_set(:@udid, 'SIM-1')
    @lifecycle.define_singleton_method(:pid_path) { pid_path }
    @lifecycle.define_singleton_method(:log_path) { log_path }

    killed = []
    Process.stub(:kill, proc { |signal, pid| killed << [signal, pid] }) do
      @lifecycle.stop
    end

    assert_equal [['TERM', 1234]], killed
    refute_path_exists pid_path
  end
end
