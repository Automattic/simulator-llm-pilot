# frozen_string_literal: true

require_relative 'test_helper'

class AgentTest < Minitest::Test
  def setup
    @config = build_config
    @logger, = build_logger
    @test_case = SimulatorLLMPilot::TestParser::TestCase.new(
      title: 'Publish Post',
      file_path: '/tmp/publish.md',
      raw_content: sample_markdown,
      sections: {
        'Steps' => 'Tap publish.',
        'Verification' => 'Verify via REST.',
        'Cleanup' => 'Delete the post.'
      }
    )
  end

  def test_pass_is_downgraded_when_required_verification_or_cleanup_is_missing
    llm = FakeLLM.new(responses: [
                        { 'content' => [tool_use(name: 'complete_test', input: { 'status' => 'pass', 'reason' => 'done' })] }
                      ])
    executor = FakeExecutor.new

    SimulatorLLMPilot::ToolExecutor.stub(:new, executor) do
      result = SimulatorLLMPilot::Agent.new(
        test_case: @test_case,
        config: @config,
        wda: FakeWDA.new,
        simulator: FakeSimulator.new,
        llm: llm,
        logger: @logger
      ).run

      assert_equal 'fail', result[:status]
      assert_includes result[:reason], 'verification section was declared'
      assert_includes result[:reason], 'cleanup section was declared'
      assert_equal 'pass', result[:model_status]
    end
  end

  def test_returns_infra_error_when_llm_request_fails
    llm = FakeLLM.new(error: SimulatorLLMPilot::LLMError.new('Anthropic API request failed'))
    executor = FakeExecutor.new

    SimulatorLLMPilot::ToolExecutor.stub(:new, executor) do
      result = SimulatorLLMPilot::Agent.new(
        test_case: @test_case,
        config: @config,
        wda: FakeWDA.new,
        simulator: FakeSimulator.new,
        llm: llm,
        logger: @logger
      ).run

      assert_equal 'infra_error', result[:status]
      assert_includes result[:reason], 'Anthropic API request failed'
    end
  end

  def test_aborts_after_three_consecutive_infra_errors
    llm = FakeLLM.new(responses: [
                        { 'content' => [tool_use(name: 'get_accessibility_tree', input: {}, id: '1')] },
                        { 'content' => [tool_use(name: 'get_accessibility_tree', input: {}, id: '2')] },
                        { 'content' => [tool_use(name: 'get_accessibility_tree', input: {}, id: '3')] }
                      ])
    executor = FakeExecutor.new(sequence: [
                                  { result: 'INFRASTRUCTURE ERROR: down', total_infra_errors: 1, consecutive_infra_errors: 1 },
                                  { result: 'INFRASTRUCTURE ERROR: down', total_infra_errors: 2, consecutive_infra_errors: 2 },
                                  { result: 'INFRASTRUCTURE ERROR: down', total_infra_errors: 3, consecutive_infra_errors: 3 }
                                ])

    SimulatorLLMPilot::ToolExecutor.stub(:new, executor) do
      result = SimulatorLLMPilot::Agent.new(
        test_case: @test_case,
        config: @config,
        wda: FakeWDA.new,
        simulator: FakeSimulator.new,
        llm: llm,
        logger: @logger
      ).run

      assert_equal 'infra_error', result[:status]
      assert_includes result[:reason], 'consecutive infrastructure errors'
    end
  end

  def test_compresses_old_accessibility_trees_once_over_the_size_threshold
    agent = build_agent_with_trees(compress_threshold: 0)

    agent.send(:compress_old_trees!)
    messages = agent.instance_variable_get(:@messages)

    assert_includes messages[1][:content][0][:content], 'compressed to save context'
    assert_equal recent_tree, messages[3][:content][0][:content]
  end

  def test_does_not_compress_until_the_context_is_large
    # Below the threshold, history stays append-only so prompt caching keeps hitting.
    agent = build_agent_with_trees(compress_threshold: 10_000_000)

    agent.send(:compress_old_trees!)
    messages = agent.instance_variable_get(:@messages)

    assert_equal old_tree, messages[1][:content][0][:content]
    assert_equal recent_tree, messages[3][:content][0][:content]
  end

  private

  def old_tree
    @old_tree ||= "Element subtree:\n#{"Attributes: Window\n" * 200}"
  end

  def recent_tree
    @recent_tree ||= "Element subtree:\n#{"Attributes: Window\n" * 10}"
  end

  def build_agent_with_trees(compress_threshold:)
    agent = nil
    SimulatorLLMPilot::ToolExecutor.stub(:new, FakeExecutor.new) do
      agent = SimulatorLLMPilot::Agent.new(
        test_case: @test_case,
        config: @config.tap do |config|
          config.max_context_turns = 1
          config.compress_context_when_chars_exceed = compress_threshold
        end,
        wda: FakeWDA.new,
        simulator: FakeSimulator.new,
        llm: FakeLLM.new(responses: []),
        logger: @logger
      )
    end

    agent.instance_variable_set(:@messages, [
                                  { role: 'user', content: 'initial' },
                                  { role: 'user', content: [{ type: 'tool_result', content: old_tree }] },
                                  { role: 'assistant', content: [] },
                                  { role: 'user', content: [{ type: 'tool_result', content: recent_tree }] },
                                  { role: 'assistant', content: [] }
                                ])
    agent
  end
end
