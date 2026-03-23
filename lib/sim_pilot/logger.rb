# frozen_string_literal: true

module SimPilot
  class Logger
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze

    def initialize(level: :info, output: $stdout)
      @level = level
      @output = output
    end

    def debug(msg) = log(:debug, msg)
    def info(msg) = log(:info, msg)
    def warn(msg) = log(:warn, msg)
    def error(msg) = log(:error, msg)

    private

    def log(level, msg)
      return unless LEVELS[level] >= LEVELS[@level]

      timestamp = Time.now.strftime("%H:%M:%S")
      prefix = case level
               when :debug then "[DEBUG] "
               when :warn  then "[WARN]  "
               when :error then "[ERROR] "
               else ""
               end
      @output.puts "[#{timestamp}] #{prefix}#{msg}"
    end
  end
end
