# frozen_string_literal: true

require_relative "test_helper"

class TestParserTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_parse_extracts_title_and_section_bodies
    path = write_test_file(@dir, "publish.md", sample_markdown)

    test_case = SimPilot::TestParser.parse(path)

    assert_equal "Publish Post", test_case.title
    assert_equal File.expand_path(path), test_case.file_path
    assert_equal ["Steps", "Verification", "Cleanup", "Expected Outcome"], test_case.sections.keys
    assert_includes test_case.sections["Verification"], "Verify the post exists"
  end

  def test_expectation_helpers_ignore_empty_sections
    path = write_test_file(@dir, "empty.md", sample_markdown(empty_verification: true))
    test_case = SimPilot::TestParser.parse(path)

    refute SimPilot::TestParser.expects_verification?(test_case)
    assert SimPilot::TestParser.expects_cleanup?(test_case)
  end

  def test_discover_sorts_markdown_files
    write_test_file(@dir, "b.md", sample_markdown(include_cleanup: false))
    write_test_file(@dir, "a.md", sample_markdown(include_verification: false))

    files = SimPilot::TestParser.discover(@dir).map { |test_case| File.basename(test_case.file_path) }

    assert_equal ["a.md", "b.md"], files
  end
end
