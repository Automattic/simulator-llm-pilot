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
end
