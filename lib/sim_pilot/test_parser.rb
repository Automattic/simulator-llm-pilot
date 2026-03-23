# frozen_string_literal: true

module SimPilot
  class TestParser
    TestCase = Struct.new(:title, :file_path, :raw_content, :sections, keyword_init: true)

    def self.parse(file_path)
      content = File.read(file_path)
      title = content.match(/^#\s+(.+)$/)&.[](1) || File.basename(file_path, ".md")
      sections = content.scan(/^##\s+(.+)$/).flatten.map(&:strip)

      TestCase.new(
        title: title,
        file_path: File.expand_path(file_path),
        raw_content: content,
        sections: sections
      )
    end

    def self.discover(path)
      if File.file?(path) && path.end_with?(".md")
        [parse(path)]
      elsif File.directory?(path)
        Dir.glob(File.join(path, "*.md")).sort.map { |f| parse(f) }
      else
        raise "Test path not found or not a .md file: #{path}"
      end
    end

    # Check if a test case declares a verification section
    def self.expects_verification?(test_case)
      test_case.sections.any? { |s| s.match?(/verification/i) }
    end

    # Check if a test case declares a cleanup section
    def self.expects_cleanup?(test_case)
      test_case.sections.any? { |s| s.match?(/cleanup/i) }
    end
  end
end
