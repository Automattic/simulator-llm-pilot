# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @test_path = write_test_file(@dir, "publish.md", sample_markdown)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_version_prints_version
    out, = capture_io do
      SimPilot::CLI.new(["version"]).run
    end

    assert_includes out, SimPilot::VERSION
  end

  def test_run_exits_zero_when_all_tests_pass
    runner = Object.new
    runner.define_singleton_method(:run) { |_path| [{ status: "pass" }] }

    with_env("ANTHROPIC_API_KEY" => "key") do
      error = assert_raises(SystemExit) do
        capture_io do
          SimPilot::Runner.stub(:new, runner) do
            SimPilot::CLI.new([
              "run", @test_path,
              "--app-bundle-id", "org.wordpress",
              "--site-url", "https://example.test",
              "--username", "ian",
              "--app-password", "secret"
            ]).run
          end
        end
      end

      assert_equal 0, error.status
    end
  end

  def test_run_exits_one_when_any_result_is_not_pass
    runner = Object.new
    runner.define_singleton_method(:run) { |_path| [{ status: "infra_error" }] }

    with_env("ANTHROPIC_API_KEY" => "key") do
      error = assert_raises(SystemExit) do
        capture_io do
          SimPilot::Runner.stub(:new, runner) do
            SimPilot::CLI.new([
              "run", @test_path,
              "--app-bundle-id", "org.wordpress",
              "--site-url", "https://example.test",
              "--username", "ian",
              "--app-password", "secret"
            ]).run
          end
        end
      end

      assert_equal 1, error.status
    end
  end
end
