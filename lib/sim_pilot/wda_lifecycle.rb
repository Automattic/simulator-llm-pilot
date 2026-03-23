# frozen_string_literal: true

module SimPilot
  # Manages starting and stopping the WebDriverAgent xcodebuild process.
  # Adapted from the WordPress-iOS ios-sim-navigation skill scripts.
  class WDALifecycle
    def initialize(port: 8100, logger:)
      @port = port
      @logger = logger
    end

    def running?
      uri = URI("http://localhost:#{@port}/status")
      response = Net::HTTP.get_response(uri)
      response.code.to_i == 200
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError
      false
    end

    def start(udid:, wda_project_path:, max_wait: 120)
      if running?
        @logger.info "WDA already running on port #{@port}"
        return true
      end

      unless File.exist?(wda_project_path)
        raise "WebDriverAgent project not found at #{wda_project_path}.\n" \
              "Clone and build it first:\n" \
              "  git clone https://github.com/appium/WebDriverAgent.git .build/WebDriverAgent\n" \
              "  cd .build/WebDriverAgent && xcodebuild build-for-testing \\\n" \
              "    -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \\\n" \
              "    -destination 'platform=iOS Simulator,id=#{udid}' CODE_SIGNING_ALLOWED=NO"
      end

      cmd = [
        "xcodebuild", "test-without-building",
        "-project", wda_project_path,
        "-scheme", "WebDriverAgentRunner",
        "-destination", "id=#{udid}",
        "USE_PORT=#{@port}",
        "CODE_SIGNING_ALLOWED=NO"
      ]

      log_path = "/tmp/wda-#{@port}.log"
      pid_path = "/tmp/wda-#{@port}.pid"

      @logger.info "Starting WDA on port #{@port} for simulator #{udid}..."
      @logger.info "WDA log: #{log_path}"

      pid = spawn(*cmd, out: log_path, err: log_path)
      File.write(pid_path, pid.to_s)
      Process.detach(pid)

      elapsed = 0
      interval = 2
      while elapsed < max_wait
        sleep interval
        elapsed += interval

        if running?
          @logger.info "WDA ready (took #{elapsed}s)"
          return true
        end
      end

      # Failed — kill the process
      begin
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        # Already gone
      end
      raise "WDA did not start within #{max_wait}s. Check log: #{log_path}"
    end

    def stop
      pid_path = "/tmp/wda-#{@port}.pid"
      stopped = false

      if File.exist?(pid_path)
        pid = File.read(pid_path).strip.to_i
        if pid > 0
          begin
            Process.kill("TERM", pid)
            @logger.info "Sent TERM to WDA process #{pid}"
            stopped = true
          rescue Errno::ESRCH
            stopped = true
          end
        end
        File.delete(pid_path)
      end

      # Also kill any lingering xcodebuild WDA processes
      pids = `pgrep -f "xcodebuild.*WebDriverAgent" 2>/dev/null`.strip.split("\n").map(&:to_i)
      pids.each do |p|
        next if p <= 0

        begin
          Process.kill("TERM", p)
          @logger.info "Killed xcodebuild WDA process #{p}"
          stopped = true
        rescue Errno::ESRCH
          # Already gone
        end
      end

      @logger.info(stopped ? "WDA stopped" : "WDA was not running")
    end
  end
end
