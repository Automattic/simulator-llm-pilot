# frozen_string_literal: true

module SimulatorLLMPilot
  # HTTP client for WebDriverAgent running on a simulator.
  # All UI interactions (tap, swipe, type, read tree) go through this client.
  class WDAClient
    INFRA_ERROR_TYPES = [
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::ETIMEDOUT,
      Net::OpenTimeout,
      Net::ReadTimeout,
      SocketError,
      EOFError
    ].freeze

    attr_reader :session_id

    def initialize(logger:, port: 8100)
      @base_url = "http://localhost:#{port}"
      @logger = logger
      @session_id = nil
    end

    def status
      get('/status')
    end

    def create_session
      response = post('/session', {
                        capabilities: { alwaysMatch: {} }
                      })
      @session_id = response.dig('value', 'sessionId') || response['sessionId']
      raise InfraError, 'WDA did not return a session id' if @session_id.nil? || @session_id.empty?

      @logger.info "WDA session: #{@session_id}"
      @session_id
    end

    # Returns the accessibility tree as text (format=description, ~25KB)
    # or as a parsed hash (format=json, ~375KB).
    def get_tree(format: :description)
      ensure_session!
      response = get("/source?format=#{format}")
      response['value']
    end

    def tap_at(x, y)
      ensure_session!
      pointer_action([
                       { type: 'pointerMove', duration: 0, x: x, y: y },
                       { type: 'pointerDown' },
                       { type: 'pointerUp' }
                     ])
    end

    def long_press(x, y, duration_ms: 1000)
      ensure_session!
      pointer_action([
                       { type: 'pointerMove', duration: 0, x: x, y: y },
                       { type: 'pointerDown' },
                       { type: 'pause', duration: duration_ms },
                       { type: 'pointerUp' }
                     ])
    end

    def swipe(x1, y1, x2, y2, duration: 500)
      ensure_session!
      pointer_action([
                       { type: 'pointerMove', duration: 0, x: x1, y: y1 },
                       { type: 'pointerDown' },
                       { type: 'pointerMove', duration: duration, x: x2, y: y2 },
                       { type: 'pointerUp' }
                     ])
    end

    def type_text(text)
      ensure_session!
      post("/session/#{@session_id}/wda/keys", { value: text.chars })
    end

    def clear_text
      ensure_session!
      post("/session/#{@session_id}/wda/keys", { value: ["\u0001"] })
      post("/session/#{@session_id}/wda/keys", { value: ["\u007F"] })
    end

    def find_elements(using:, value:)
      ensure_session!
      response = post("/session/#{@session_id}/elements", {
                        using: using,
                        value: value
                      })
      response['value'] || []
    end

    def find_element(using:, value:)
      elements = find_elements(using: using, value: value)
      return nil if elements.empty?

      element = elements.first
      element['ELEMENT'] || element.values.first
    end

    # Find elements that are descendants of another element (e.g. the cells
    # inside a collection view). Returns the raw element hashes, in the order
    # WDA reports them.
    def find_child_elements(element_id, using:, value:)
      ensure_session!
      response = post("/session/#{@session_id}/element/#{element_id}/elements", {
                        using: using,
                        value: value
                      })
      response['value'] || []
    end

    def click_element(element_id)
      ensure_session!
      post("/session/#{@session_id}/element/#{element_id}/click")
    end

    def press_button(name)
      ensure_session!
      post("/session/#{@session_id}/wda/pressButton", { name: name })
    end

    private

    def ensure_session!
      return if @session_id

      raise InfraError, 'WDA session is not available'
    end

    def pointer_action(actions)
      post("/session/#{@session_id}/actions", {
             actions: [{
               type: 'pointer',
               id: 'finger1',
               parameters: { pointerType: 'touch' },
               actions: actions
             }]
           })
    end

    def get(path)
      uri = URI("#{@base_url}#{path}")
      response = Net::HTTP.start(uri.hostname, uri.port) do |http|
        http.read_timeout = 30
        http.open_timeout = 10
        http.request(Net::HTTP::Get.new(uri))
      end

      parse_response('GET', path, response)
    rescue *INFRA_ERROR_TYPES => e
      raise InfraError, "WDA GET #{path} failed: #{e.message}"
    end

    def post(path, body = nil)
      uri = URI("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body) if body

      response = Net::HTTP.start(uri.hostname, uri.port) do |http|
        http.read_timeout = 30
        http.open_timeout = 10
        http.request(request)
      end

      parse_response('POST', path, response)
    rescue *INFRA_ERROR_TYPES => e
      raise InfraError, "WDA POST #{path} failed: #{e.message}"
    end

    def parse_response(method, path, response)
      parsed = JSON.parse(response.body)
      error_source = error_metadata_source(parsed)
      error_type = error_source&.[]('error')
      error_message = error_source&.[]('message')

      raise InfraError, "WDA #{method} #{path} failed (HTTP #{response.code}): #{error_message || response.body}" if response.code.to_i >= 500

      raise InfraError, "WDA #{method} #{path} failed: #{error_type}: #{error_message}" if infra_session_error?(error_type)

      if response.code.to_i >= 400 || error_type
        detail = [error_type, error_message].compact.join(': ')
        detail = response.body if detail.empty?
        raise "WDA #{method} #{path} failed (HTTP #{response.code}): #{detail}"
      end

      parsed
    rescue JSON::ParserError => e
      raise InfraError, "WDA #{method} #{path} returned invalid JSON: #{e.message}"
    end

    def infra_session_error?(error_type)
      ['invalid session id', 'session not created'].include?(error_type)
    end

    def error_metadata_source(parsed)
      return parsed unless parsed.is_a?(Hash)

      value = parsed['value']
      return value if value.is_a?(Hash)

      parsed
    end
  end
end
