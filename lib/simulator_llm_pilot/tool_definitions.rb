# frozen_string_literal: true

module SimulatorLLMPilot
  # Defines the fixed set of tools the LLM can call.
  # This is the sandbox boundary — the LLM cannot do anything outside these tools.
  module ToolDefinitions
    def self.all
      [
        {
          name: 'get_accessibility_tree',
          description: 'Get the current accessibility tree of the app UI in compact text format. ' \
                       'Each line shows: Type, address, frame {{x, y}, {width, height}}, and optional ' \
                       'identifier/label. Use this to understand the screen and find elements to interact with. ' \
                       'Call it after a swipe or type_text to verify the UI updated; you do NOT need it after ' \
                       'tap_and_wait, which already returns the updated tree. If you only need one element\'s ' \
                       'presence or state, prefer assert_element_exists — it is much cheaper than the full tree.',
          input_schema: {
            type: 'object',
            properties: {},
            required: []
          }
        },
        {
          name: 'tap',
          description: 'Tap at specific screen coordinates. To compute coordinates from the accessibility tree ' \
                       'frame {{x, y}, {width, height}}: tap_x = x + width/2, tap_y = y + height/2. ' \
                       'To tap the same point repeatedly, pass times instead of issuing one call per tap.',
          input_schema: {
            type: 'object',
            properties: {
              x: { type: 'number', description: 'X coordinate' },
              y: { type: 'number', description: 'Y coordinate' },
              times: {
                type: 'number',
                description: 'Number of sequential taps with a short pause between them (default: 1, max: 30)'
              }
            },
            required: %w[x y]
          }
        },
        {
          name: 'tap_element',
          description: 'Find an element by accessibility identifier or label and tap it. ' \
                       'More reliable than coordinate-based tapping when an element has a stable ID. ' \
                       'Provide identifier, label, or both (identifier is tried first). When a step ' \
                       'requires tapping the same element repeatedly (e.g. Undo 10 times), pass times ' \
                       'in ONE call instead of issuing one call per tap, then verify the resulting state.',
          input_schema: {
            type: 'object',
            properties: {
              identifier: { type: 'string', description: 'Accessibility identifier (developer-assigned)' },
              label: { type: 'string', description: 'Accessibility label (visible text)' },
              times: {
                type: 'number',
                description: 'Number of sequential taps with a short pause between them (default: 1, max: 30)'
              }
            },
            required: []
          }
        },
        {
          name: 'tap_and_wait',
          description: 'Tap a target and return the resulting accessibility tree in one call. Prefer this ' \
                       'over a separate tap + get_accessibility_tree — it returns the post-tap tree, so do ' \
                       'NOT call get_accessibility_tree afterwards. You MUST provide a target: identifier ' \
                       'or label to tap an element, or both x and y to tap coordinates. Optionally pass ' \
                       'wait_for (an identifier or label you expect on the resulting screen) to keep ' \
                       're-reading the tree until it appears, up to timeout_seconds. Without wait_for, it ' \
                       'waits briefly for the accessibility tree to change before returning.',
          input_schema: {
            type: 'object',
            properties: {
              identifier: { type: 'string', description: 'Accessibility identifier of the element to tap' },
              label: { type: 'string', description: 'Accessibility label of the element to tap' },
              x: { type: 'number', description: 'X coordinate to tap (use instead of identifier/label)' },
              y: { type: 'number', description: 'Y coordinate to tap (use together with x)' },
              wait_for: {
                type: 'string',
                description: 'Identifier or label expected on the resulting screen; waits until it appears'
              },
              timeout_seconds: {
                type: 'number',
                description: 'Max seconds to wait for wait_for (0.5 to 10, default 3)'
              }
            },
            required: []
          }
        },
        {
          name: 'tap_collection_cell',
          description: 'Tap the Nth visible cell inside a collection/grid view, found by the ' \
                       "collection's accessibility identifier. Returns a one-line result, not a tree. " \
                       'Use this to pick an item from a grid — e.g. a photo in a media picker — ' \
                       'instead of reading the full tree to compute cell coordinates.',
          input_schema: {
            type: 'object',
            properties: {
              collection_identifier: {
                type: 'string',
                description: 'Accessibility identifier of the collection/grid view'
              },
              index: { type: 'number', description: 'Zero-based index of the cell to tap (default: 0)' }
            },
            required: %w[collection_identifier]
          }
        },
        {
          name: 'assert_element_exists',
          description: 'Check that an element is currently on screen and return a one-line result that ' \
                       'includes the element\'s type, label, value, and enabled state — enough to verify ' \
                       'a control\'s state (e.g. a switch value) without reading the full accessibility ' \
                       'tree. Use it IN PLACE OF a tree fetch for verification steps, not in addition to ' \
                       'one. Provide identifier, label, or both (identifier is tried first). Only assert ' \
                       'conditions the test REQUIRES — failures are enforced: if the most recent assertion ' \
                       'on a target is still failing when the test completes, a pass result is downgraded ' \
                       'to fail, so re-run the assertion after recovering. For exploratory probes, use ' \
                       'wait_for_element instead (not enforced).',
          input_schema: {
            type: 'object',
            properties: {
              identifier: { type: 'string', description: 'Accessibility identifier (developer-assigned)' },
              label: { type: 'string', description: 'Accessibility label (visible text)' }
            },
            required: []
          }
        },
        {
          name: 'assert_element_absent',
          description: 'Check that an element is NOT currently on screen and return a one-line result. ' \
                       'Use this to verify something disappeared (e.g. after removing or dismissing it) ' \
                       'without reading the full accessibility tree. Only assert conditions the test ' \
                       'REQUIRES — failures are enforced: if the most recent assertion on a target is ' \
                       'still failing when the test completes, a pass result is downgraded to fail, so ' \
                       're-run the assertion after recovering.',
          input_schema: {
            type: 'object',
            properties: {
              identifier: { type: 'string', description: 'Accessibility identifier (developer-assigned)' },
              label: { type: 'string', description: 'Accessibility label (visible text)' }
            },
            required: []
          }
        },
        {
          name: 'wait_for_element',
          description: 'Wait until an element appears on screen, polling up to timeout_seconds, and ' \
                       'return a one-line result including the element\'s type, label, value, and ' \
                       'enabled state. Use this after an action that triggers a transition when you ' \
                       'know an identifier or label expected on the destination screen — it replaces ' \
                       'the wait + get_accessibility_tree pattern in a single, much cheaper call. Also ' \
                       'the right tool for exploratory probes ("is X here?") with a short timeout — ' \
                       'unlike the assert tools, a timeout here is not enforced as a test failure.',
          input_schema: {
            type: 'object',
            properties: {
              identifier: { type: 'string', description: 'Accessibility identifier (developer-assigned)' },
              label: { type: 'string', description: 'Accessibility label (visible text)' },
              timeout_seconds: {
                type: 'number',
                description: 'Max seconds to wait (0.5 to 10, default 3)'
              }
            },
            required: []
          }
        },
        {
          name: 'swipe',
          description: 'Swipe from one point to another. For scrolling DOWN (reveal content below): ' \
                       'swipe from lower y to upper y. For scrolling UP (reveal content above): swipe ' \
                       'from upper y to lower y. Use x near the right edge (screen_width - 30) for ' \
                       'vertical scrolling to avoid hitting interactive elements.',
          input_schema: {
            type: 'object',
            properties: {
              x1: { type: 'number', description: 'Start X' },
              y1: { type: 'number', description: 'Start Y' },
              x2: { type: 'number', description: 'End X' },
              y2: { type: 'number', description: 'End Y' },
              duration: { type: 'number', description: 'Duration in milliseconds (default: 500)' }
            },
            required: %w[x1 y1 x2 y2]
          }
        },
        {
          name: 'type_text',
          description: 'Type text into the currently focused text field. A field must be ' \
                       'tapped/focused first. Each character is sent individually.',
          input_schema: {
            type: 'object',
            properties: {
              text: { type: 'string', description: 'Text to type' }
            },
            required: %w[text]
          }
        },
        {
          name: 'clear_text',
          description: 'Clear text in the currently focused field (select all + delete).',
          input_schema: {
            type: 'object',
            properties: {},
            required: []
          }
        },
        {
          name: 'take_screenshot',
          description: 'Capture a screenshot of the current simulator screen. Use sparingly — ' \
                       'prefer the accessibility tree for navigation decisions.',
          input_schema: {
            type: 'object',
            properties: {
              label: { type: 'string', description: 'Descriptive label for the screenshot file' }
            },
            required: %w[label]
          }
        },
        {
          name: 'launch_app',
          description: 'Relaunch the app with test credentials. Terminates the running instance ' \
                       'first for a clean state. The app will be pre-configured with the test ' \
                       'site URL, username, and password via launch arguments.',
          input_schema: {
            type: 'object',
            properties: {},
            required: []
          }
        },
        {
          name: 'rest_api_call',
          description: 'Make a WordPress REST API call to the test site. ' \
                       'Authentication is handled automatically via the configured credentials. ' \
                       'You MUST set purpose to setup, verification, or cleanup so the runner can ' \
                       'enforce that declared test sections were actually executed.',
          input_schema: {
            type: 'object',
            properties: {
              purpose: {
                type: 'string',
                enum: %w[setup verification cleanup],
                description: 'Why this call is being made'
              },
              method: { type: 'string', enum: %w[GET POST PUT DELETE], description: 'HTTP method' },
              path: {
                type: 'string',
                description: 'API path relative to site (e.g., /wp-json/wp/v2/posts)'
              },
              body: { type: 'object', description: 'Request body for POST/PUT' },
              query: {
                type: 'object',
                description: 'Query parameters as key-value pairs (e.g., {"search": "title", "status": "publish"})'
              }
            },
            required: %w[purpose method path]
          }
        },
        {
          name: 'wait',
          description: 'Wait for a specified duration. Max 10 seconds. If you are waiting for a ' \
                       'specific element to appear, use wait_for_element instead — it returns as soon ' \
                       'as the element shows up and costs one call instead of wait + a tree fetch.',
          input_schema: {
            type: 'object',
            properties: {
              seconds: { type: 'number', description: 'Seconds to wait (0.5 to 10)' }
            },
            required: %w[seconds]
          }
        },
        {
          name: 'complete_test',
          description: 'Mark the test as complete. MUST be called exactly once when done, ' \
                       'whether the test passed or failed.',
          input_schema: {
            type: 'object',
            properties: {
              status: { type: 'string', enum: %w[pass fail], description: 'Test result' },
              reason: { type: 'string', description: 'Brief explanation of the result' }
            },
            required: %w[status reason]
          }
        }
      ]
    end
  end
end
