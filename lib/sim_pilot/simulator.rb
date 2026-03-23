# frozen_string_literal: true

module SimPilot
  # Wrapper around xcrun simctl for simulator operations.
  class Simulator
    def initialize(logger:)
      @logger = logger
    end

    def booted_device
      output, status = Open3.capture2("xcrun", "simctl", "list", "devices", "booted", "-j")
      return nil unless status.success?

      data = JSON.parse(output)
      data.fetch("devices", {}).each_value do |devices|
        devices.each do |d|
          return { udid: d["udid"], name: d["name"] } if d["state"] == "Booted"
        end
      end
      nil
    end

    def launch_app(udid, bundle_id, args: {})
      cmd = ["xcrun", "simctl", "launch", "--terminate-running-process", udid, bundle_id]
      args.each { |key, value| cmd.push("-#{key}", value.to_s) }

      output, err, status = Open3.capture3(*cmd)
      raise InfraError, "Failed to launch #{bundle_id}: #{err}" unless status.success?

      @logger.info "Launched #{bundle_id}"
      output
    end

    def terminate_app(udid, bundle_id)
      Open3.capture3("xcrun", "simctl", "terminate", udid, bundle_id)
    end

    def screenshot(udid, path)
      _, err, status = Open3.capture3("xcrun", "simctl", "io", udid, "screenshot", path)
      raise InfraError, "Failed to take screenshot: #{err}" unless status.success?

      path
    end

    def boot(name_or_udid)
      _, err, status = Open3.capture3("xcrun", "simctl", "boot", name_or_udid)
      raise InfraError, "Failed to boot simulator '#{name_or_udid}': #{err}" unless status.success?
    end
  end
end
