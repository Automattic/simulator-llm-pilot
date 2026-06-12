# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'stringio'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'simulator_llm_pilot'

class Object
  def stub(method_name, replacement)
    singleton = class << self; self; end
    backup = :"__simulator_llm_pilot_stub__#{method_name}__#{object_id}"
    had_method = respond_to?(method_name, true)

    singleton.alias_method(backup, method_name) if had_method
    singleton.define_method(method_name) do |*args, **kwargs, &block|
      if replacement.respond_to?(:call)
        replacement.call(*args, **kwargs, &block)
      else
        replacement
      end
    end

    yield
  ensure
    begin
      singleton.send(:remove_method, method_name)
    rescue StandardError
      nil
    end
    if had_method
      singleton.alias_method(method_name, backup)
      begin
        singleton.send(:remove_method, backup)
      rescue StandardError
        nil
      end
    end
  end
end

module SimulatorLLMPilotTestHelpers
  FakeResponse = Struct.new(:code, :body)

  class FakeHTTPTransport
    attr_reader :requests
    attr_accessor :read_timeout, :open_timeout

    def initialize(response: nil, &handler)
      @response = response
      @handler = handler
      @requests = []
    end

    def request(request)
      @requests << request
      @handler ? @handler.call(request) : @response
    end
  end

  class FakeWDA
    attr_accessor :tree, :session_id
    attr_reader :calls

    def initialize
      @tree = "Element subtree:\nAttributes: Window"
      @session_id = 'session-123'
      @calls = []
      @failures = {}
      @find_element_result = nil
      @find_element_results = {}
      @child_elements = {}
    end

    def fail_on(method_name, error)
      @failures[method_name] = error
    end

    attr_writer :find_element_result

    def set_find_element_result(using:, value:, result:)
      @find_element_results[[using, value]] = result
    end

    def create_session
      maybe_raise(:create_session)
      @calls << [:create_session]
      @session_id
    end

    def get_tree(format:)
      maybe_raise(:get_tree)
      @calls << [:get_tree, format]
      @tree
    end

    def tap_at(x, y)
      maybe_raise(:tap_at)
      @calls << [:tap_at, x, y]
    end

    def swipe(x1, y1, x2, y2, duration:)
      maybe_raise(:swipe)
      @calls << [:swipe, x1, y1, x2, y2, duration]
    end

    def type_text(text)
      maybe_raise(:type_text)
      @calls << [:type_text, text]
    end

    def clear_text
      maybe_raise(:clear_text)
      @calls << [:clear_text]
    end

    def find_element(using:, value:)
      maybe_raise(:find_element)
      @calls << [:find_element, using, value]
      return @find_element_results.fetch([using, value]) if @find_element_results.key?([using, value])

      @find_element_result
    end

    def click_element(element_id)
      maybe_raise(:click_element)
      @calls << [:click_element, element_id]
    end

    def set_child_elements(element_id, cells)
      @child_elements[element_id] = cells
    end

    def find_child_elements(element_id, using:, value:)
      maybe_raise(:find_child_elements)
      @calls << [:find_child_elements, element_id, using, value]
      @child_elements.fetch(element_id, [])
    end

    private

    def maybe_raise(method_name)
      error = @failures[method_name]
      raise error if error
    end
  end

  class FakeSimulator
    attr_accessor :booted_device_result
    attr_reader :calls

    def initialize
      @booted_device_result = { udid: 'SIM-1', name: 'iPhone 16' }
      @calls = []
      @failures = {}
    end

    def fail_on(method_name, error)
      @failures[method_name] = error
    end

    def booted_device(name: nil)
      maybe_raise(:booted_device)
      @calls << [:booted_device, name]
      return @booted_device_result if name.nil? || @booted_device_result.nil?
      return @booted_device_result if @booted_device_result[:name] == name

      nil
    end

    def launch_app(udid, bundle_id, args:)
      maybe_raise(:launch_app)
      @calls << [:launch_app, udid, bundle_id, args]
      'launched'
    end

    def terminate_app(udid, bundle_id)
      maybe_raise(:terminate_app)
      @calls << [:terminate_app, udid, bundle_id]
    end

    def screenshot(udid, path)
      maybe_raise(:screenshot)
      @calls << [:screenshot, udid, path]
      path
    end

    def boot(name_or_udid)
      maybe_raise(:boot)
      @calls << [:boot, name_or_udid]
    end

    private

    def maybe_raise(method_name)
      error = @failures[method_name]
      raise error if error
    end
  end

  class FakeLLM
    attr_reader :calls

    def initialize(responses: [], error: nil)
      @responses = responses.dup
      @error = error
      @calls = []
    end

    def create_message(**kwargs)
      @calls << kwargs
      raise @error if @error
      raise 'No response queued' if @responses.empty?

      @responses.shift
    end
  end

  class FakeExecutor
    attr_accessor :test_completed, :test_status, :test_reason
    attr_reader :tool_usage, :total_infra_errors, :consecutive_infra_errors

    def initialize(sequence: [])
      @sequence = sequence.dup
      @tool_usage = Hash.new(0)
      @total_infra_errors = 0
      @consecutive_infra_errors = 0
      @test_completed = false
      @test_status = nil
      @test_reason = nil
      @rest_calls = Hash.new { |hash, purpose| hash[purpose] = { called: false, satisfied: false } }
    end

    def execute(tool_name, input)
      @tool_usage[tool_name] += 1

      if tool_name == 'complete_test'
        @test_completed = true
        @test_status = input['status']
        @test_reason = input['reason']
      elsif tool_name == 'rest_api_call'
        purpose = input['purpose']
        @rest_calls[purpose][:called] = true
        @rest_calls[purpose][:satisfied] = true
      end

      outcome = @sequence.shift
      apply_outcome(outcome, tool_name)
    end

    def rest_api_called?(purpose = nil)
      return @rest_calls.values.any? { |state| state[:called] } if purpose.nil?

      @rest_calls[purpose][:called]
    end

    def rest_api_satisfied?(purpose)
      @rest_calls[purpose][:satisfied]
    end

    private

    def apply_outcome(outcome, tool_name)
      return default_result(tool_name) if outcome.nil?

      return outcome.call(tool_name, self) if outcome.respond_to?(:call)

      if outcome.is_a?(Hash)
        @total_infra_errors = outcome[:total_infra_errors] if outcome.key?(:total_infra_errors)
        @consecutive_infra_errors = outcome[:consecutive_infra_errors] if outcome.key?(:consecutive_infra_errors)
        if outcome[:rest_call]
          purpose = outcome[:rest_call][:purpose]
          @rest_calls[purpose][:called] = outcome[:rest_call].fetch(:called, true)
          @rest_calls[purpose][:satisfied] = outcome[:rest_call].fetch(:satisfied, false)
        end
        return outcome.fetch(:result, default_result(tool_name))
      end

      outcome
    end

    def default_result(tool_name)
      tool_name == 'complete_test' ? 'complete' : 'ok'
    end
  end

  class FakeLifecycle
    attr_reader :calls

    def initialize(start_error: nil)
      @start_error = start_error
      @calls = []
    end

    def start(**kwargs)
      @calls << [:start, kwargs]
      raise @start_error if @start_error

      true
    end

    def stop
      @calls << [:stop]
      true
    end
  end

  def build_logger(level: :debug)
    io = StringIO.new
    [SimulatorLLMPilot::Logger.new(level: level, output: io), io]
  end

  def build_config
    config = SimulatorLLMPilot::Config.new
    config.anthropic_api_key = 'anthropic-key'
    config.app_bundle_id = 'org.wordpress'
    config.site_url = 'https://example.test'
    config.username = 'ian'
    config.app_password = 'secret'
    config.simulator_udid = 'SIM-1'
    config
  end

  def sample_markdown(include_verification: true, include_cleanup: true, empty_verification: false)
    verification_body = empty_verification ? '' : "- Verify the post exists.\n"
    cleanup = include_cleanup ? "## Cleanup\n- Delete the post.\n\n" : ''
    verification = include_verification ? "## Verification\n#{verification_body}\n" : ''

    <<~MARKDOWN
      # Publish Post

      ## Steps
      1. Tap publish.

      #{verification}
      #{cleanup}
      ## Expected Outcome
      - The post is visible.
    MARKDOWN
  end

  def write_test_file(dir, name, content = sample_markdown)
    path = File.join(dir, name)
    File.write(path, content)
    path
  end

  def tool_use(name:, input:, id: 'tool-1')
    { 'type' => 'tool_use', 'id' => id, 'name' => name, 'input' => input }
  end

  def fake_response(code:, body:)
    FakeResponse.new(code.to_s, body)
  end

  def fake_status(success)
    Object.new.tap do |status|
      status.define_singleton_method(:success?) { success }
    end
  end

  def with_env(values)
    previous = {}
    values.each do |key, value|
      previous[key] = ENV.fetch(key, nil)
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end

module Minitest
  class Test
    include SimulatorLLMPilotTestHelpers
  end
end
