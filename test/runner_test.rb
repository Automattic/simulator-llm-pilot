# frozen_string_literal: true

require_relative 'test_helper'

class RunnerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @config = build_config
    @config.results_dir = File.join(@dir, 'results')
    @logger, = build_logger
    @test_path = write_test_file(@dir, 'publish.md', sample_markdown)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_run_writes_results_for_a_passing_test
    simulator = FakeSimulator.new
    lifecycle = FakeLifecycle.new
    wda = FakeWDA.new
    llm = Object.new
    agent = Struct.new(:result) do
      def run
        result
      end
    end.new(
      {
        status: 'pass',
        reason: 'done',
        model_status: 'pass',
        model_reason: 'done',
        enforced_failures: [],
        tool_usage: { 'launch_app' => 1, 'complete_test' => 1 },
        verification_expected: true,
        verification_ran: true,
        verification_satisfied: true,
        cleanup_expected: true,
        cleanup_ran: true,
        cleanup_satisfied: true,
        turns: 4,
        total_infra_errors: 0
      }
    )

    SimulatorLLMPilot::Simulator.stub(:new, simulator) do
      SimulatorLLMPilot::WDALifecycle.stub(:new, lifecycle) do
        SimulatorLLMPilot::WDAClient.stub(:new, wda) do
          SimulatorLLMPilot::LLMClient.stub(:new, llm) do
            SimulatorLLMPilot::Agent.stub(:new, agent) do
              results = SimulatorLLMPilot::Runner.new(config: @config, logger: @logger).run(@test_path)

              assert_equal(['pass'], results.map { |result| result[:status] })
              assert_equal(1, wda.calls.count { |call| call.first == :create_session })
              assert_path_exists File.join(@config.results_dir, 'results.md')
              assert_includes File.read(File.join(@config.results_dir, 'results.md')), 'Verification: passed'
              assert_equal [:stop], lifecycle.calls.last
            end
          end
        end
      end
    end
  end

  def test_prepare_session_failure_becomes_infra_error_result
    simulator = FakeSimulator.new
    lifecycle = FakeLifecycle.new
    wda = FakeWDA.new
    wda.fail_on(:create_session, SimulatorLLMPilot::InfraError.new('session down'))

    SimulatorLLMPilot::Simulator.stub(:new, simulator) do
      SimulatorLLMPilot::WDALifecycle.stub(:new, lifecycle) do
        SimulatorLLMPilot::WDAClient.stub(:new, wda) do
          SimulatorLLMPilot::LLMClient.stub(:new, Object.new) do
            results = SimulatorLLMPilot::Runner.new(config: @config, logger: @logger).run(@test_path)

            assert_equal(['infra_error'], results.map { |result| result[:status] })
            assert_includes results.first[:reason], 'Failed to create WDA session'
          end
        end
      end
    end
  end

  def test_resolve_simulator_prefers_requested_name_over_other_booted_device
    simulator = FakeSimulator.new
    simulator.booted_device_result = { udid: 'SIM-OTHER', name: 'iPhone 15' }
    lifecycle = FakeLifecycle.new
    wda = FakeWDA.new
    llm = Object.new
    agent = Struct.new(:result) do
      def run
        result
      end
    end.new(
      {
        status: 'pass',
        reason: 'done',
        model_status: 'pass',
        model_reason: 'done',
        enforced_failures: [],
        tool_usage: {},
        verification_expected: false,
        verification_ran: false,
        verification_satisfied: true,
        cleanup_expected: false,
        cleanup_ran: false,
        cleanup_satisfied: true,
        turns: 1,
        total_infra_errors: 0
      }
    )
    @config.simulator_udid = nil
    @config.simulator_name = 'iPhone 16'

    boot_lookup_count = 0
    simulator.define_singleton_method(:booted_device) do |name: nil|
      @calls << [:booted_device, name]
      if name == 'iPhone 16'
        boot_lookup_count += 1
        boot_lookup_count > 1 ? { udid: 'SIM-16', name: 'iPhone 16' } : nil
      else
        { udid: 'SIM-OTHER', name: 'iPhone 15' }
      end
    end

    SimulatorLLMPilot::Simulator.stub(:new, simulator) do
      SimulatorLLMPilot::WDALifecycle.stub(:new, lifecycle) do
        SimulatorLLMPilot::WDAClient.stub(:new, wda) do
          SimulatorLLMPilot::LLMClient.stub(:new, llm) do
            SimulatorLLMPilot::Agent.stub(:new, agent) do
              SimulatorLLMPilot::Runner.new(config: @config, logger: @logger).run(@test_path)

              assert_equal 'SIM-16', @config.simulator_udid
              assert_includes simulator.calls, [:boot, 'iPhone 16']
            end
          end
        end
      end
    end
  end

  def test_usage_summary_formats_tokens_and_cache_hit_rate
    runner = SimulatorLLMPilot::Runner.new(config: @config, logger: @logger)
    fake_llm = Struct.new(:usage_totals).new(
      {
        requests: 5,
        input_tokens: 1000,
        output_tokens: 200,
        cache_creation_input_tokens: 500,
        cache_read_input_tokens: 8500
      }
    )

    summary = runner.send(:run_usage_summary, fake_llm)

    assert_includes summary, 'requests: 5'
    assert_includes summary, 'cache read: 8500'
    assert_includes summary, 'cache hit: 85.0%'
    refute_includes summary, '$'
  end

  def test_usage_summary_is_nil_without_a_usage_capable_client
    runner = SimulatorLLMPilot::Runner.new(config: @config, logger: @logger)

    assert_nil runner.send(:run_usage_summary, Object.new)
  end
end
