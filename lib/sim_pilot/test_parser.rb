# frozen_string_literal: true

module SimPilot
  class TestParser
    TestCase = Struct.new(:title, :file_path, :raw_content, keyword_init: true)

    def self.parse(file_path)
      content = File.read(file_path)
      title = content.match(/^#\s+(.+)$/)&.[](1) || File.basename(file_path, ".md")

      TestCase.new(
        title: title,
        file_path: File.expand_path(file_path),
        raw_content: content
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
  end
end
