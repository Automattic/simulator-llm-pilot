# frozen_string_literal: true

module SimulatorLLMPilot
  # The core agent loop for a single test case.
  # Sends the test context to the LLM, receives tool calls, executes them,
  # and repeats until the test is complete or limits are hit.
  class Agent
    SYSTEM_PROMPT = <<~PROMPT
      You are an iOS app test executor. You navigate a WordPress or Jetpack iOS app
      running in a simulator to execute test cases written in natural language.

      You interact with the app EXCLUSIVELY through the provided tools. You cannot
      run shell commands or access the filesystem directly.

      ## Navigation Strategy

      1. ALWAYS start by calling launch_app, then wait 3 seconds, then get_accessibility_tree.
      2. The accessibility tree shows every UI element with its type, frame, label, and identifier.
      3. To compute tap coordinates from a frame {{x, y}, {width, height}}:
         tap_x = x + width / 2
         tap_y = y + height / 2
      4. After EVERY action (tap, swipe, type), call get_accessibility_tree to verify
         the UI changed as expected before proceeding to the next step.
      5. If an element isn't visible, scroll down by swiping up from the right edge.

      ## Element Finding Priority

      1. accessibility identifier (most stable, use tap_element with identifier)
      2. label text (use tap_element with label, or find in tree and tap by coordinates)
      3. type + context (e.g., "Button inside NavigationBar")
      4. partial label match (for dynamic labels like "3 Posts")

      ## Scrolling

      For vertical scrolling, always use x = screen_width - 30 to avoid accidentally
      tapping interactive elements. Swipe distances should be about 1/3 of screen height.
      After scrolling, re-fetch the tree. If the tree is unchanged after a scroll,
      you've reached the end of the list.

      ## Handling Common Situations

      - **System alerts** (permissions, tracking): Look for Alert/Sheet elements in
        the tree. Tap "Allow", "OK", or "Don't Allow" as appropriate.
      - **Loading states**: If the tree shows a loading indicator, wait 2 seconds
        and re-fetch the tree.
      - **Login**:
        - This runner is configured for a self-hosted site, not a WordPress.com account.
        - NEVER tap "Continue with WordPress.com", NEVER enter WordPress.com email/password,
          and NEVER request a login link.
        - NEVER type a password manually. The app password is already passed via the
          launch arguments for self-hosted login.
        - Tap "Enter your existing site address", then enter the site host first
          (without scheme, for example `example.com`). If the app rejects the host-only
          form, try the full site URL once.
        - If you reach any WordPress.com email/password screen, back out and return to
          the self-hosted flow.
      - **Failed tap**: If the tree is unchanged after a tap, try: (a) re-fetch tree
        and recompute coordinates, (b) use tap_element, (c) try a slightly offset position.

      ## REST API Usage

      - When using rest_api_call, set purpose=setup for prerequisite/setup work.
      - When executing a Verification section, set purpose=verification.
      - When executing a Cleanup section, set purpose=cleanup.
      - A declared Verification or Cleanup section is not complete unless you actually
        call rest_api_call with the matching purpose.

      ## Rules

      - NEVER call the same tool with the same arguments more than 3 times in a row.
      - If stuck after 5 retries on the same step, mark the test as failed.
      - ALWAYS call complete_test exactly once when done, whether pass or fail.
      - Keep your text responses minimal — focus on tool calls, not explanations.
    PROMPT

    MAX_CONSECUTIVE_INFRA_ERRORS = 3

    def initialize(test_case:, config:, wda:, simulator:, llm:, logger:)
      @test_case = test_case
      @config = config
      @llm = llm
      @logger = logger
      @executor = ToolExecutor.new(wda: wda, simulator: simulator, config: config, logger: logger)
      @messages = []
      @turn_count = 0
    end

    def run
      @logger.info "Starting: #{@test_case.title}"

      app_name = @config.app_bundle_id.include?('jetpack') ? 'Jetpack' : 'WordPress'
      site_host = URI.parse(@config.site_url).host || @config.site_url

      user_message = <<~MSG
        ## App
        #{app_name} (Bundle ID: #{@config.app_bundle_id})

        ## Test Site
        - URL: #{@config.site_url}
        - Host: #{site_host}
        - Username: #{@config.username}
        - Authentication mode: self-hosted via launch arguments only

        ## Declared Sections
        - Verification required: #{verification_expected? ? 'yes' : 'no'}
        - Cleanup required: #{cleanup_expected? ? 'yes' : 'no'}

        ## Test Case (from #{File.basename(@test_case.file_path)})

        #{@test_case.raw_content}

        ---
        Execute this test case now. Start by launching the app, then follow the steps.
      MSG

      @messages = [{ role: 'user', content: user_message }]
      tools = ToolDefinitions.all
      start_time = Time.now

      loop do
        @turn_count += 1

        if @turn_count > @config.max_turns_per_test
          @logger.warn "Max turns (#{@config.max_turns_per_test}) exceeded"
          return build_result('fail', "Exceeded maximum tool call turns (#{@config.max_turns_per_test})")
        end

        elapsed = Time.now - start_time
        if elapsed > @config.test_timeout
          @logger.warn "Timeout (#{@config.test_timeout}s) exceeded"
          return build_result('fail', "Test timed out after #{elapsed.round}s")
        end

        compress_old_trees!

        response = @llm.create_message(
          system: SYSTEM_PROMPT,
          messages: @messages,
          tools: tools
        )

        assistant_content = response['content']
        @messages << { role: 'assistant', content: assistant_content }

        assistant_content.each do |block|
          next unless block['type'] == 'text' && !block['text'].strip.empty?

          @logger.debug "LLM thinks: #{block['text'][0..150]}"
        end

        tool_uses = assistant_content.select { |block| block['type'] == 'tool_use' }
        return if_completed_or_fail('LLM stopped without calling complete_test') if tool_uses.empty?

        tool_results = tool_uses.map do |tool_use|
          tool_result = @executor.execute(tool_use['name'], tool_use['input'])
          {
            type: 'tool_result',
            tool_use_id: tool_use['id'],
            content: tool_result.to_s
          }
        end

        @messages << { role: 'user', content: tool_results }

        if @executor.consecutive_infra_errors >= MAX_CONSECUTIVE_INFRA_ERRORS
          @logger.error "Aborting: #{@executor.consecutive_infra_errors} consecutive infrastructure errors"
          return build_result(
            'infra_error',
            "Aborted after #{@executor.consecutive_infra_errors} consecutive infrastructure errors"
          )
        end

        return if_completed_or_fail(nil) if @executor.test_completed
      end
    rescue LLMError => e
      @logger.error e.message
      build_result('infra_error', e.message)
    end

    private

    def if_completed_or_fail(fallback_reason)
      if @executor.test_completed
        build_result(@executor.test_status, @executor.test_reason)
      else
        build_result('fail', fallback_reason)
      end
    end

    def build_result(model_status, model_reason)
      verification_expected = verification_expected?
      cleanup_expected = cleanup_expected?
      verification_ran = @executor.rest_api_called?('verification')
      cleanup_ran = @executor.rest_api_called?('cleanup')
      verification_satisfied = !verification_expected || @executor.rest_api_satisfied?('verification')
      cleanup_satisfied = !cleanup_expected || @executor.rest_api_satisfied?('cleanup')

      enforced_failures = if model_status == 'infra_error'
                            []
                          else
                            build_enforced_failures(
                              verification_expected: verification_expected,
                              verification_ran: verification_ran,
                              verification_satisfied: verification_satisfied,
                              cleanup_expected: cleanup_expected,
                              cleanup_ran: cleanup_ran,
                              cleanup_satisfied: cleanup_satisfied
                            )
                          end

      status, reason = enforce_result(model_status, model_reason, enforced_failures)

      {
        status: status,
        reason: reason,
        model_status: model_status,
        model_reason: model_reason,
        enforced_failures: enforced_failures,
        tool_usage: @executor.tool_usage.dup,
        verification_expected: verification_expected,
        verification_ran: verification_ran,
        verification_satisfied: verification_satisfied,
        cleanup_expected: cleanup_expected,
        cleanup_ran: cleanup_ran,
        cleanup_satisfied: cleanup_satisfied,
        turns: @turn_count,
        total_infra_errors: @executor.total_infra_errors
      }
    end

    def build_enforced_failures(verification_expected:, verification_ran:, verification_satisfied:,
                                cleanup_expected:, cleanup_ran:, cleanup_satisfied:)
      failures = []

      if verification_expected
        if !verification_ran
          failures << 'verification section was declared but no verification REST call was made'
        elsif !verification_satisfied
          failures << 'verification REST calls did not complete successfully'
        end
      end

      if cleanup_expected
        if !cleanup_ran
          failures << 'cleanup section was declared but no cleanup REST call was made'
        elsif !cleanup_satisfied
          failures << 'cleanup REST calls did not complete successfully'
        end
      end

      failures
    end

    def enforce_result(model_status, model_reason, enforced_failures)
      return [model_status, model_reason] if enforced_failures.empty? || model_status == 'infra_error'

      combined_reason = "#{model_reason}. Runner enforcement: #{enforced_failures.join('; ')}"
      [model_status == 'pass' ? 'fail' : model_status, combined_reason]
    end

    def verification_expected?
      TestParser.expects_verification?(@test_case)
    end

    def cleanup_expected?
      TestParser.expects_cleanup?(@test_case)
    end

    # Compress accessibility tree content in older tool results to manage
    # context window size and reduce token cost. Keeps the most recent
    # trees intact so the model can still reference the current UI state.
    def compress_old_trees!
      preserve_recent = @config.max_context_turns * 2
      cutoff = @messages.length - preserve_recent

      return if cutoff <= 1

      (1...cutoff).each do |index|
        msg = @messages[index]
        next unless msg[:role] == 'user'

        content = msg[:content]
        next unless content.is_a?(Array)

        content.each do |block|
          next unless block[:type] == 'tool_result'
          next unless block[:content].is_a?(String)

          text = block[:content]
          next unless text.length > 500 && accessibility_tree?(text)

          block[:content] = "[Accessibility tree — #{text.lines.size} lines, compressed to save context]"
        end
      end
    end

    def accessibility_tree?(text)
      text.include?('Element subtree:') || text.match?(/\AAttributes: Window/)
    end
  end
end
