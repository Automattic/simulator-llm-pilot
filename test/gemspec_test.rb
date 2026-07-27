# frozen_string_literal: true

require_relative 'test_helper'

class GemspecTest < Minitest::Test
  def test_declares_base64_as_a_runtime_dependency
    gemspec_path = File.expand_path('../simulator-llm-pilot.gemspec', __dir__)
    specification = Gem::Specification.load(gemspec_path)
    dependency = specification.runtime_dependencies.find { |item| item.name == 'base64' }

    refute_nil dependency
    assert dependency.requirement.satisfied_by?(Gem::Version.new('0.3.0'))
  end
end
