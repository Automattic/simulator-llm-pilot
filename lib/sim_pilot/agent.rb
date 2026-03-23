# frozen_string_literal: true

module SimPilot
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
      - **Login**: If the app shows a login screen after launch, tap "Enter your
        existing site address", type the site URL, then tap Continue. The app will
        auto-login using the launch arguments.
      - **Failed tap**: If the tree is unchanged after a tap, try: (a) re-fetch tree
        and recompute coordinates, (b) use tap_element, (c) try a slightly offset position.

      ## Rules

      - NEVER call the same tool with the same arguments more than 3 times in a row.
      - If stuck after 5 retries on the same step, mark the test as failed.
      - ALWAYS call complete_test exactly once when done, whether pass or fail.
      - Keep your text responses minimal — focus on tool calls, not explanations.
    PROMPT

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

      app_name = @config.app_bundle_id.include?("jetpack") ? "Jetpack" : "WordPress"

      user_message = <<~MSG
        ## App
        #{app_name} (Bundle ID: #{@config.app_bundle_id})

        ## Test Site
        - URL: #{@config.site_url}
        - Username: #{@config.username}

        ## Test Case (from #{File.basename(@test_case.file_path)})

        #{@test_case.raw_content}

        ---
        Execute this test case now. Start by launching the app, then follow the steps.
      MSG

      @messages = [{ role: "user", content: user_message }]
      tools = ToolDefinitions.all
      start_time = Time.now

      loop do
        @turn_count += 1

        if @turn_count > @config.max_turns_per_test
          @logger.warn "Max turns (#{@config.max_turns_per_test}) exceeded"
          return result("fail", "Exceeded maximum tool call turns (#{@config.max_turns_per_test})")
        end

        elapsed = Time.now - start_time
        if elapsed > @config.test_timeout
          @logger.warn "Timeout (#{@config.test_timeout}s) exceeded"
          return result("fail", "Test timed out after #{elapsed.round}s")
        end

        response = @llm.create_message(
          system: SYSTEM_PROMPT,
          messages: @messages,
          tools: tools
        )

        assistant_content = response["content"]
        @messages << { role: "assistant", content: assistant_content }

        # Log any text the model produces
        assistant_content.each do |block|
          next unless block["type"] == "text" && !block["text"].strip.empty?

          @logger.debug "LLM thinks: #{block["text"][0..150]}"
        end

        # Collect tool use blocks
        tool_uses = assistant_content.select { |b| b["type"] == "tool_use" }

        if tool_uses.empty?
          # Model stopped without tool calls
          return if_completed_or_fail("LLM stopped without calling complete_test")
        end

        # Execute tools and build results
        tool_results = tool_uses.map do |tool_use|
          tool_result = @executor.execute(tool_use["name"], tool_use["input"])
          {
            type: "tool_result",
            tool_use_id: tool_use["id"],
            content: tool_result.to_s
          }
        end

        @messages << { role: "user", content: tool_results }

        # Check if any tool call completed the test
        return if_completed_or_fail(nil) if @executor.test_completed
      end
    end

    private

    def if_completed_or_fail(fallback_reason)
      if @executor.test_completed
        result(@executor.test_status, @executor.test_reason)
      else
        result("fail", fallback_reason)
      end
    end

    def result(status, reason)
      { status: status, reason: reason }
    end
  end
end
