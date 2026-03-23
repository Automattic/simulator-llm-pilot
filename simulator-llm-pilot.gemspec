# frozen_string_literal: true

require_relative 'lib/simulator_llm_pilot/version'

Gem::Specification.new do |spec|
  spec.name = 'simulator-llm-pilot'
  spec.version = SimulatorLLMPilot::VERSION
  spec.authors = 'Automattic'
  spec.email = 'mobile@automattic.com'

  spec.summary = 'AI-driven iOS E2E test runner'
  spec.description = 'Runs natural-language iOS E2E tests by bridging an LLM (Claude API) ' \
                     'with WebDriverAgent and iOS Simulator. Tests are markdown files with ' \
                     'plain-language steps that the AI executes autonomously through a ' \
                     'sandboxed set of tools — no arbitrary code execution.'
  spec.homepage = 'https://github.com/Automattic/simulator-llm-pilot'
  spec.license = 'MPL-2.0'
  spec.required_ruby_version = '>= 3.2.0'

  spec.files = Dir['lib/**/*', 'bin/*', 'LICENSE', 'README.md']
  spec.bindir = 'bin'
  spec.executables = ['simulator-llm-pilot']
  spec.require_paths = ['lib']

  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'rubocop-minitest'
  spec.add_development_dependency 'rubocop-rake'
end
