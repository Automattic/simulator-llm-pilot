# frozen_string_literal: true

require_relative 'test_helper'

class TranscriptWriterTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @config = build_config
    @config.results_dir = @dir
    @logger, = build_logger
    @test_case = SimulatorLLMPilot::TestParser::TestCase.new(
      title: 'View Site',
      file_path: '/tmp/view-site.md',
      raw_content: '# View Site',
      sections: {}
    )
    @transcript = {
      system: 'Use anthropic-key with neither ian@example.test nor https://example.test.',
      tools: [],
      messages: [
        {
          role: 'user',
          content: 'Username: ian Password: secret Host: example.test Basic: aWFuOnNlY3JldA=='
        }
      ]
    }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_failure_policy_writes_one_compressed_redacted_transcript
    @config.transcript_policy = 'failures'

    path = writer.write(
      test_case: @test_case,
      result: failure_result,
      transcript: @transcript,
      index: 0
    )

    assert_equal File.join(@dir, 'transcripts', '01-view-site.json.gz'), path
    payload = JSON.parse(Zlib::GzipReader.open(path, &:read))
    serialized = JSON.generate(payload)

    %w[anthropic-key secret https://example.test example.test].each do |sensitive|
      refute_includes serialized, sensitive
    end
    refute_match(/(?<![[:alnum:]_.-])ian(?![[:alnum:]_.-])/, serialized)
    %w[
      [REDACTED:ANTHROPIC_API_KEY]
      [REDACTED:APP_PASSWORD]
      [REDACTED:BASIC_AUTH]
      [REDACTED:SITE_URL]
      [REDACTED:SITE_HOST]
      [REDACTED:USERNAME]
    ].each do |placeholder|
      assert_includes serialized, placeholder
    end
  end

  def test_failure_policy_does_not_write_passing_transcripts
    @config.transcript_policy = 'failures'

    path = writer.write(
      test_case: @test_case,
      result: failure_result.merge(status: 'pass'),
      transcript: @transcript,
      index: 0
    )

    assert_nil path
    refute_path_exists File.join(@dir, 'transcripts')
  end

  def test_all_policy_writes_passing_transcripts
    @config.transcript_policy = 'all'

    path = writer.write(
      test_case: @test_case,
      result: failure_result.merge(status: 'pass'),
      transcript: @transcript,
      index: 0
    )

    assert_path_exists path
  end

  def test_redaction_does_not_mutate_the_live_conversation
    @config.transcript_policy = 'failures'

    writer.write(
      test_case: @test_case,
      result: failure_result,
      transcript: @transcript,
      index: 0
    )

    assert_includes @transcript[:messages].first[:content], 'secret'
  end

  private

  def writer
    SimulatorLLMPilot::TranscriptWriter.new(config: @config, logger: @logger)
  end

  def failure_result
    {
      status: 'fail',
      model_status: 'pass',
      reason: 'Runner enforcement'
    }
  end
end
