# frozen_string_literal: true

module SimPilot
  # HTTP client for WebDriverAgent running on a simulator.
  # All UI interactions (tap, swipe, type, read tree) go through this client.
  class WDAClient
    attr_reader :session_id

    def initialize(port: 8100, logger:)
      @base_url = "http://localhost:#{port}"
      @logger = logger
      @session_id = nil
    end

    def status
      get("/status")
    end

    def create_session
      response = post("/session", {
        capabilities: { alwaysMatch: {} }
      })
      @session_id = response.dig("value", "sessionId")
      @logger.info "WDA session: #{@session_id}"
      @session_id
    end

    # Returns the accessibility tree as text (format=description, ~25KB)
    # or as a parsed hash (format=json, ~375KB).
    def get_tree(format: :description)
      response = get("/source?format=#{format}")
      response["value"]
    end

    def tap_at(x, y)
      pointer_action([
        { type: "pointerMove", duration: 0, x: x, y: y },
        { type: "pointerDown" },
        { type: "pointerUp" }
      ])
    end

    def long_press(x, y, duration_ms: 1000)
      pointer_action([
        { type: "pointerMove", duration: 0, x: x, y: y },
        { type: "pointerDown" },
        { type: "pause", duration: duration_ms },
        { type: "pointerUp" }
      ])
    end

    def swipe(x1, y1, x2, y2, duration: 500)
      pointer_action([
        { type: "pointerMove", duration: 0, x: x1, y: y1 },
        { type: "pointerDown" },
        { type: "pointerMove", duration: duration, x: x2, y: y2 },
        { type: "pointerUp" }
      ])
    end

    def type_text(text)
      post("/session/#{@session_id}/wda/keys", { value: text.chars })
    end

    def clear_text
      # Select all (Ctrl+A) then delete
      post("/session/#{@session_id}/wda/keys", { value: ["\u0001"] })
      post("/session/#{@session_id}/wda/keys", { value: ["\u007F"] })
    end

    # Find elements by accessibility id or label.
    # using: "accessibility id", "link text", "partial link text",
    #        "class name", "xpath", "predicate string", "class chain"
    def find_elements(using:, value:)
      response = post("/session/#{@session_id}/elements", {
        using: using,
        value: value
      })
      response["value"] || []
    end

    def find_element(using:, value:)
      elements = find_elements(using: using, value: value)
      return nil if elements.empty?

      element = elements.first
      element["ELEMENT"] || element.values.first
    end

    def click_element(element_id)
      post("/session/#{@session_id}/element/#{element_id}/click")
    end

    def press_button(name)
      post("/session/#{@session_id}/wda/pressButton", { name: name })
    end

    private

    def pointer_action(actions)
      post("/session/#{@session_id}/actions", {
        actions: [{
          type: "pointer",
          id: "finger1",
          parameters: { pointerType: "touch" },
          actions: actions
        }]
      })
    end

    def get(path)
      uri = URI("#{@base_url}#{path}")
      response = Net::HTTP.get_response(uri)
      JSON.parse(response.body)
    rescue StandardError => e
      raise "WDA GET #{path} failed: #{e.message}"
    end

    def post(path, body = nil)
      uri = URI("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) if body

      response = Net::HTTP.start(uri.hostname, uri.port) do |http|
        http.read_timeout = 30
        http.request(request)
      end

      JSON.parse(response.body)
    rescue StandardError => e
      raise "WDA POST #{path} failed: #{e.message}"
    end
  end
end
