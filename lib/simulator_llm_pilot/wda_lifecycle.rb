# frozen_string_literal: true

module SimulatorLLMPilot
  # Manages starting and stopping the WebDriverAgent xcodebuild process.
  # Each instance is scoped to a specific simulator UDID and port, so
  # parallel runs on different simulators won't interfere with each other.
  class WDALifecycle
    def initialize(logger:, port: 8100)
      @port = port
      @logger = logger
      @udid = nil # set on start, used for scoped pid/log paths
    end

    def running?
      uri = URI("http://localhost:#{@port}/status")
      response = Net::HTTP.get_response(uri)
      response.code.to_i == 200
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError
      false
    end

    def start(udid:, wda_project_path:, wda_derived_data_path: nil, max_wait: 120)
      @udid = udid
      wda_derived_data_path ||= File.join(File.dirname(wda_project_path), 'DerivedData')

      if running?
        if own_process_running?
          @logger.info "WDA already running on port #{@port} for #{udid}"
          return true
        else
          raise "Port #{@port} is already in use by another WDA process. " \
                'Use --wda-port to specify a different port for parallel runs.'
        end
      end

      unless File.exist?(wda_project_path)
        raise "WebDriverAgent project not found at #{wda_project_path}.\n" \
              "Clone and build it first:\n  " \
              "git clone https://github.com/appium/WebDriverAgent.git .build/WebDriverAgent\n  " \
              "cd .build/WebDriverAgent && xcodebuild build-for-testing \\\n    " \
              "-project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \\\n    " \
              "-destination 'platform=iOS Simulator,id=#{udid}' \\\n    " \
              "-derivedDataPath '#{wda_derived_data_path}' CODE_SIGNING_ALLOWED=NO"
      end

      cmd = [
        'xcodebuild', 'test-without-building',
        '-project', wda_project_path,
        '-scheme', 'WebDriverAgentRunner',
        '-destination', "id=#{udid}",
        '-derivedDataPath', wda_derived_data_path,
        "USE_PORT=#{@port}",
        'CODE_SIGNING_ALLOWED=NO'
      ]

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

      begin
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        # Already gone
      end
      raise "WDA did not start within #{max_wait}s. Check log: #{log_path}"
    end

    def stop
      stopped = false

      if @udid && File.exist?(pid_path)
        pid = File.read(pid_path).strip.to_i
        if pid.positive?
          begin
            Process.kill('TERM', pid)
            @logger.info "Sent TERM to WDA process #{pid}"
            stopped = true
          rescue Errno::ESRCH
            stopped = true
          end
        end
        File.delete(pid_path)
      end

      @logger.info(stopped ? 'WDA stopped' : 'WDA was not running')
    end

    private

    def own_process_running?
      return false unless File.exist?(pid_path)

      pid = File.read(pid_path).strip.to_i
      return false unless pid.positive?

      # Check if the process is still alive
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def pid_path
      "/tmp/wda-#{@udid}-#{@port}.pid"
    end

    def log_path
      "/tmp/wda-#{@udid}-#{@port}.log"
    end
  end
end
