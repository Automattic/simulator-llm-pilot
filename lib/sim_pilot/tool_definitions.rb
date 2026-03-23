# frozen_string_literal: true

module SimPilot
  # Defines the fixed set of tools the LLM can call.
  # This is the sandbox boundary — the LLM cannot do anything outside these tools.
  module ToolDefinitions
    def self.all
      [
        {
          name: "get_accessibility_tree",
          description: "Get the current accessibility tree of the app UI in compact text format. " \
                       "Each line shows: Type, address, frame {{x, y}, {width, height}}, and optional " \
                       "identifier/label. Use this to understand the screen and find elements to interact with. " \
                       "ALWAYS call this after every action to verify the UI updated.",
          input_schema: {
            type: "object",
            properties: {},
            required: []
          }
        },
        {
          name: "tap",
          description: "Tap at specific screen coordinates. To compute coordinates from the accessibility tree " \
                       "frame {{x, y}, {width, height}}: tap_x = x + width/2, tap_y = y + height/2.",
          input_schema: {
            type: "object",
            properties: {
              x: { type: "number", description: "X coordinate" },
              y: { type: "number", description: "Y coordinate" }
            },
            required: %w[x y]
          }
        },
        {
          name: "tap_element",
          description: "Find an element by accessibility identifier or label and tap it. " \
                       "More reliable than coordinate-based tapping when an element has a stable ID. " \
                       "Provide identifier, label, or both (identifier is tried first).",
          input_schema: {
            type: "object",
            properties: {
              identifier: { type: "string", description: "Accessibility identifier (developer-assigned)" },
              label: { type: "string", description: "Accessibility label (visible text)" }
            },
            required: []
          }
        },
        {
          name: "swipe",
          description: "Swipe from one point to another. For scrolling DOWN (reveal content below): " \
                       "swipe from lower y to upper y. For scrolling UP (reveal content above): swipe " \
                       "from upper y to lower y. Use x near the right edge (screen_width - 30) for " \
                       "vertical scrolling to avoid hitting interactive elements.",
          input_schema: {
            type: "object",
            properties: {
              x1: { type: "number", description: "Start X" },
              y1: { type: "number", description: "Start Y" },
              x2: { type: "number", description: "End X" },
              y2: { type: "number", description: "End Y" },
              duration: { type: "number", description: "Duration in milliseconds (default: 500)" }
            },
            required: %w[x1 y1 x2 y2]
          }
        },
        {
          name: "type_text",
          description: "Type text into the currently focused text field. A field must be " \
                       "tapped/focused first. Each character is sent individually.",
          input_schema: {
            type: "object",
            properties: {
              text: { type: "string", description: "Text to type" }
            },
            required: %w[text]
          }
        },
        {
          name: "clear_text",
          description: "Clear text in the currently focused field (select all + delete).",
          input_schema: {
            type: "object",
            properties: {},
            required: []
          }
        },
        {
          name: "take_screenshot",
          description: "Capture a screenshot of the current simulator screen. Use sparingly — " \
                       "prefer the accessibility tree for navigation decisions.",
          input_schema: {
            type: "object",
            properties: {
              label: { type: "string", description: "Descriptive label for the screenshot file" }
            },
            required: %w[label]
          }
        },
        {
          name: "launch_app",
          description: "Relaunch the app with test credentials. Terminates the running instance " \
                       "first for a clean state. The app will be pre-configured with the test " \
                       "site URL, username, and password via launch arguments.",
          input_schema: {
            type: "object",
            properties: {},
            required: []
          }
        },
        {
          name: "rest_api_call",
          description: "Make a WordPress REST API call to the test site for verification or cleanup. " \
                       "Authentication is handled automatically via the configured credentials.",
          input_schema: {
            type: "object",
            properties: {
              method: { type: "string", enum: %w[GET POST PUT DELETE], description: "HTTP method" },
              path: {
                type: "string",
                description: "API path relative to site (e.g., /wp-json/wp/v2/posts)"
              },
              body: { type: "object", description: "Request body for POST/PUT" },
              query: {
                type: "object",
                description: 'Query parameters as key-value pairs (e.g., {"search": "title", "status": "publish"})'
              }
            },
            required: %w[method path]
          }
        },
        {
          name: "wait",
          description: "Wait for a specified duration. Max 10 seconds.",
          input_schema: {
            type: "object",
            properties: {
              seconds: { type: "number", description: "Seconds to wait (0.5 to 10)" }
            },
            required: %w[seconds]
          }
        },
        {
          name: "complete_test",
          description: "Mark the test as complete. MUST be called exactly once when done, " \
                       "whether the test passed or failed.",
          input_schema: {
            type: "object",
            properties: {
              status: { type: "string", enum: %w[pass fail], description: "Test result" },
              reason: { type: "string", description: "Brief explanation of the result" }
            },
            required: %w[status reason]
          }
        }
      ]
    end
  end
end
