# frozen_string_literal: true

require_relative 'test_helper'

class CLITest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @test_path = write_test_file(@dir, 'publish.md', sample_markdown)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_version_prints_version
    out, = capture_io do
      SimulatorLLMPilot::CLI.new(['version']).run
    end

    assert_includes out, SimulatorLLMPilot::VERSION
  end

  def test_run_exits_zero_when_all_tests_pass
    runner = Object.new
    runner.define_singleton_method(:run) { |_path| [{ status: 'pass' }] }

    with_env('ANTHROPIC_API_KEY' => 'key') do
      error = assert_raises(SystemExit) do
        capture_io do
          SimulatorLLMPilot::Runner.stub(:new, runner) do
            SimulatorLLMPilot::CLI.new([
                                         'run', @test_path,
                                         '--app-bundle-id', 'org.wordpress',
                                         '--site-url', 'https://example.test',
                                         '--username', 'ian',
                                         '--app-password', 'secret'
                                       ]).run
          end
        end
      end

      assert_equal 0, error.status
    end
  end

  def test_run_exits_one_when_any_result_is_not_pass
    runner = Object.new
    runner.define_singleton_method(:run) { |_path| [{ status: 'infra_error' }] }

    with_env('ANTHROPIC_API_KEY' => 'key') do
      error = assert_raises(SystemExit) do
        capture_io do
          SimulatorLLMPilot::Runner.stub(:new, runner) do
            SimulatorLLMPilot::CLI.new([
                                         'run', @test_path,
                                         '--app-bundle-id', 'org.wordpress',
                                         '--site-url', 'https://example.test',
                                         '--username', 'ian',
                                         '--app-password', 'secret'
                                       ]).run
          end
        end
      end

      assert_equal 1, error.status
    end
  end

  def test_run_parses_the_compress_context_over_flag
    config = run_cli_and_capture_config('--compress-context-over', '1500000')

    assert_equal 1_500_000, config.compress_context_when_chars_exceed
  end

  def test_compress_context_over_zero_disables_compression
    config = run_cli_and_capture_config('--compress-context-over', '0')

    assert_nil config.compress_context_when_chars_exceed
  end

  def test_run_parses_the_rest_api_policy_flag
    config = run_cli_and_capture_config('--rest-api-policy', 'verification-readonly')

    assert_equal 'verification-readonly', config.rest_api_policy
  end

  def test_run_parses_the_transcript_policy_flag
    config = run_cli_and_capture_config('--transcript-policy', 'failures')

    assert_equal 'failures', config.transcript_policy
  end

  private

  def run_cli_and_capture_config(*extra_args)
    captured_config = nil
    runner = Object.new
    runner.define_singleton_method(:run) { |_path| [{ status: 'pass' }] }
    runner_factory = proc do |config:, **_kwargs|
      captured_config = config
      runner
    end

    with_env('ANTHROPIC_API_KEY' => 'key') do
      assert_raises(SystemExit) do
        capture_io do
          SimulatorLLMPilot::Runner.stub(:new, runner_factory) do
            SimulatorLLMPilot::CLI.new([
                                         'run', @test_path,
                                         '--app-bundle-id', 'org.wordpress',
                                         '--site-url', 'https://example.test',
                                         '--username', 'ian',
                                         '--app-password', 'secret',
                                         *extra_args
                                       ]).run
          end
        end
      end
    end

    captured_config
  end
end
