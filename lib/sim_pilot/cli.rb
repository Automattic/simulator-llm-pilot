# frozen_string_literal: true

module SimPilot
  class CLI
    def initialize(argv)
      @argv = argv.dup
      @config = Config.new
      @log_level = :info
    end

    def run
      command = @argv.shift

      case command
      when "run"
        parse_run_options!
        run_tests
      when "version", "--version", "-v"
        puts "sim_pilot #{VERSION}"
      when "help", "--help", "-h", nil
        print_help
      else
        $stderr.puts "Unknown command: #{command}"
        $stderr.puts ""
        print_help
        exit 1
      end
    rescue ArgumentError => e
      $stderr.puts e.message
      exit 1
    rescue Interrupt
      $stderr.puts "\nInterrupted"
      exit 130
    rescue StandardError => e
      $stderr.puts "Error: #{e.message}"
      $stderr.puts e.backtrace.first(5).map { |l| "  #{l}" }.join("\n") if @log_level == :debug
      exit 1
    end

    private

    def parse_run_options!
      @test_path = nil

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: sim_pilot run <test_file_or_directory> [options]"
        opts.separator ""
        opts.separator "Required:"
        opts.separator "  ANTHROPIC_API_KEY    Environment variable with your API key"
        opts.separator ""
        opts.separator "Options:"

        opts.on("--app-bundle-id ID", "App bundle ID (e.g., org.wordpress)") do |v|
          @config.app_bundle_id = v
        end

        opts.on("--site-url URL", "WordPress site URL (or SIM_PILOT_SITE_URL env)") do |v|
          @config.site_url = v
        end

        opts.on("--username USER", "WordPress username (or SIM_PILOT_USERNAME env)") do |v|
          @config.username = v
        end

        opts.on("--app-password PASS", "WordPress app password (or SIM_PILOT_APP_PASSWORD env)") do |v|
          @config.app_password = v
        end

        opts.on("--simulator-udid UDID", "Simulator UDID (auto-detects booted simulator)") do |v|
          @config.simulator_udid = v
        end

        opts.on("--simulator-name NAME", "Boot this simulator if none running") do |v|
          @config.simulator_name = v
        end

        opts.on("--wda-port PORT", Integer, "WDA port (default: 8100)") do |v|
          @config.wda_port = v
        end

        opts.on("--wda-project PATH", "Path to WebDriverAgent.xcodeproj") do |v|
          @config.wda_project_path = v
        end

        opts.on("--results-dir DIR", "Output directory for results") do |v|
          @config.results_dir = v
        end

        opts.on("--model MODEL", "Anthropic model (default: claude-sonnet-4-20250514)") do |v|
          @config.anthropic_model = v
        end

        opts.on("--max-turns N", Integer, "Max tool call turns per test (default: 100)") do |v|
          @config.max_turns_per_test = v
        end

        opts.on("--timeout SECS", Integer, "Timeout per test in seconds (default: 600)") do |v|
          @config.test_timeout = v
        end

        opts.on("--max-context-turns N", Integer, "Compress trees older than N turns (default: 20)") do |v|
          @config.max_context_turns = v
        end

        opts.on("--rest-api-prefix PREFIX", "Allowed REST API path prefix (default: /wp-json/)") do |v|
          @config.rest_api_allowed_prefix = v
        end

        opts.on("--debug", "Enable debug logging") do
          @log_level = :debug
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end
      end

      parser.permute!(@argv)
      @test_path = @argv.shift

      unless @test_path
        $stderr.puts parser
        exit 1
      end
    end

    def run_tests
      @config.validate!

      logger = Logger.new(level: @log_level)
      logger.info "sim_pilot v#{VERSION}"
      logger.info "Model: #{@config.anthropic_model}"
      logger.info "Tests: #{@test_path}"
      logger.info ""

      runner = Runner.new(config: @config, logger: logger)
      results = runner.run(@test_path)

      any_failure = results.any? { |r| r[:status] != "pass" }
      exit(any_failure ? 1 : 0)
    end

    def print_help
      puts <<~HELP
        sim_pilot v#{VERSION} — AI-driven iOS E2E test runner

        Runs natural-language test cases (markdown files) against a WordPress or
        Jetpack iOS app in a simulator. An LLM navigates the app through a sandboxed
        set of tools (WDA + simctl) — no arbitrary code execution.

        Usage:
          sim_pilot run <test_file_or_dir> [options]
          sim_pilot version
          sim_pilot help

        Example:
          sim_pilot run tests/create-blank-page.md \\
            --app-bundle-id org.wordpress \\
            --site-url https://test.example.com \\
            --username testuser \\
            --app-password "xxxx xxxx xxxx xxxx"

          sim_pilot run tests/ \\
            --app-bundle-id com.automattic.jetpack \\
            --site-url https://test.example.com \\
            --username testuser \\
            --app-password "xxxx xxxx xxxx xxxx"

        Environment variables:
          ANTHROPIC_API_KEY       Required — Claude API key
          SIM_PILOT_SITE_URL      WordPress site URL
          SIM_PILOT_USERNAME      WordPress username
          SIM_PILOT_APP_PASSWORD  WordPress application password

        Run 'sim_pilot run --help' for all options.
      HELP
    end
  end
end
