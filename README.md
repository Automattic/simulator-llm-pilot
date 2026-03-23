# sim_pilot

AI-driven iOS end-to-end test runner. Executes test cases written as plain-language markdown files against a WordPress or Jetpack iOS app in a simulator, using an LLM to navigate the UI through a sandboxed set of tools.

## Why

Traditional XCUITest-based UI tests are brittle and expensive to maintain. When they break, they tend to stay broken for weeks while PRs keep merging against a red CI. The AI-driven approach replaces rigid, coordinate-coupled test code with natural-language test cases that an LLM interprets and executes at runtime.

The key problem with running an LLM CLI (like Claude Code) directly in CI is that it requires broad permissions — arbitrary shell commands, network access, filesystem writes — which is a security and reliability risk. **sim_pilot solves this by acting as an intermediary**: it owns all I/O and exposes only a fixed set of operations to the LLM. The model can think, but it can only act through the narrow interface the tool defines.

## How it works

```
┌──────────────────────────────────────────────────┐
│  sim_pilot                                       │
│                                                  │
│  ┌──────────┐      ┌───────────────────────┐     │
│  │  Claude   │◄────►│  Tool Executor        │     │
│  │  API      │      │  (sandboxed actions)  │     │
│  │  (Sonnet) │      │                       │     │
│  └──────────┘      │  ┌─────────────────┐  │     │
│                     │  │ WDA HTTP Client │  │     │
│  ┌──────────┐      │  │ simctl wrapper  │  │     │
│  │ Markdown  │      │  │ WP REST API     │  │     │
│  │ test file │      │  └─────────────────┘  │     │
│  └──────────┘      └───────────────────────┘     │
│                                                  │
│  iOS Simulator (booted, app installed)           │
└──────────────────────────────────────────────────┘
```

1. **sim_pilot** reads a markdown test file (e.g., "Create and Publish a Blank Page").
2. It sends the test steps to the **Claude API** along with a fixed set of tool definitions.
3. The LLM responds with tool calls (`get_accessibility_tree`, `tap`, `type_text`, etc.).
4. **sim_pilot** executes each tool call against the simulator via **WebDriverAgent** and `xcrun simctl`.
5. Results are returned to the LLM, which decides the next action.
6. This loops until the LLM calls `complete_test` with a pass/fail verdict.

The LLM **cannot** execute shell commands, write scripts, access the filesystem, or make arbitrary network requests. Every action goes through the tool executor.

## Available tools

The LLM has access to exactly these operations:

| Tool | Description |
|------|-------------|
| `get_accessibility_tree` | Read the current UI element tree (types, labels, identifiers, coordinates) |
| `tap` | Tap at screen coordinates |
| `tap_element` | Find element by accessibility ID or label and tap it |
| `swipe` | Swipe gesture (scrolling, navigation) |
| `type_text` | Type into the focused text field |
| `clear_text` | Select all + delete in the focused field |
| `take_screenshot` | Capture simulator screenshot |
| `launch_app` | (Re)launch the app with test credentials |
| `rest_api_call` | WordPress REST API call (for verification/cleanup) |
| `wait` | Pause up to 10 seconds |
| `complete_test` | Mark the test as pass or fail |

## Test format

Tests are markdown files with natural-language sections. Example:

```markdown
# Publish a Text Post

## Prerequisites
- Logged in to the app with the test account.

## Steps
1. Navigate to the "My Site" tab.
2. Tap the FAB or "+" button to create a new post.
3. If a bottom sheet appears, select "Post".
4. Enter "Rich post title" as the post title.
5. Tap the "Publish" button in the top-right corner.
6. If a pre-publish confirmation appears, tap "Publish" again.
7. Dismiss the confirmation screen by tapping "Done".

## Verification (REST API)
- Search for a post titled "Rich post title" with status "publish".
- Verify the post exists.

## Cleanup (REST API)
- Trash the post created during this test.

## Expected Outcome
- The post is published and confirmed via the REST API.
- The post is cleaned up after verification.
```

## Prerequisites

- **macOS** with Xcode and iOS Simulators
- **Ruby** >= 3.0
- **WebDriverAgent** built for simulator use (see [Setup](#wda-setup))
- **ANTHROPIC_API_KEY** environment variable
- The app built and installed on a booted simulator

## Installation

```bash
cd sim_pilot
gem build sim_pilot.gemspec
gem install sim_pilot-0.1.0.gem
```

Or run directly from the repo:

```bash
ruby bin/sim_pilot run ...
```

## Usage

### Run a single test

```bash
sim_pilot run path/to/create-blank-page.md \
  --app-bundle-id org.wordpress \
  --site-url https://test.example.com \
  --username testuser \
  --app-password "xxxx xxxx xxxx xxxx"
```

### Run a full test suite

```bash
sim_pilot run path/to/ui-tests/ \
  --app-bundle-id org.wordpress \
  --site-url https://test.example.com \
  --username testuser \
  --app-password "xxxx xxxx xxxx xxxx"
```

### All options

```
--app-bundle-id ID       App bundle ID (e.g., org.wordpress, com.automattic.jetpack)
--site-url URL           WordPress site URL (or SIM_PILOT_SITE_URL env)
--username USER          WordPress username (or SIM_PILOT_USERNAME env)
--app-password PASS      WordPress application password (or SIM_PILOT_APP_PASSWORD env)
--simulator-udid UDID    Target simulator (auto-detects booted simulator if omitted)
--simulator-name NAME    Boot this simulator if none running
--wda-port PORT          WDA port (default: 8100)
--wda-project PATH       Path to WebDriverAgent.xcodeproj
--results-dir DIR        Output directory for results
--model MODEL            Anthropic model (default: claude-sonnet-4-20250514)
--max-turns N            Max tool call rounds per test (default: 100)
--timeout SECS           Timeout per test in seconds (default: 600)
--debug                  Enable debug logging (shows LLM reasoning and tool details)
```

### Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | Yes | Claude API key |
| `SIM_PILOT_SITE_URL` | No | WordPress site URL (alternative to `--site-url`) |
| `SIM_PILOT_USERNAME` | No | WordPress username (alternative to `--username`) |
| `SIM_PILOT_APP_PASSWORD` | No | WordPress app password (alternative to `--app-password`) |

## WDA setup

sim_pilot uses [WebDriverAgent](https://github.com/appium/WebDriverAgent) to interact with the simulator UI.

```bash
# Clone
git clone https://github.com/appium/WebDriverAgent.git .build/WebDriverAgent

# Build for your target simulator
cd .build/WebDriverAgent
xcodebuild build-for-testing \
  -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  CODE_SIGNING_ALLOWED=NO
```

sim_pilot looks for WDA at `.build/WebDriverAgent/WebDriverAgent.xcodeproj` relative to the working directory. Use `--wda-project` to override.

## Output

Results are written to `results/<timestamp>/`:

```
results/2026-03-23-1430/
├── results.md              # Summary with pass/fail for each test
└── screenshots/            # Failure screenshots
    └── create-blank-page-failure-1.png
```

The process exits with code 0 if all tests pass, 1 if any fail.

## Project structure

```
lib/sim_pilot/
├── agent.rb             # Core loop: LLM <-> tool executor
├── cli.rb               # Command-line interface
├── config.rb            # Configuration and validation
├── llm_client.rb        # Anthropic Messages API (stdlib net/http)
├── logger.rb            # Structured timestamped logging
├── runner.rb            # Orchestration: WDA lifecycle, test loop, results
├── simulator.rb         # xcrun simctl wrapper
├── test_parser.rb       # Markdown test discovery and parsing
├── tool_definitions.rb  # The 11 sandboxed tools (the security boundary)
├── tool_executor.rb     # Executes tool calls against WDA/simctl/REST
├── wda_client.rb        # WebDriverAgent HTTP client
└── wda_lifecycle.rb     # WDA process start/stop
```

Zero external dependencies. Uses only Ruby stdlib.

## CI usage

For Buildkite or other CI systems:

```bash
# Ensure simulator is booted and app is installed
xcrun simctl boot "iPhone 16"
# ... build and install the app ...

# Run tests
sim_pilot run Tests/AgentTests/ui-tests/ \
  --app-bundle-id org.wordpress \
  --site-url "$TEST_SITE_URL" \
  --username "$TEST_USERNAME" \
  --app-password "$TEST_APP_PASSWORD" \
  --results-dir "$BUILDKITE_ARTIFACT_DIR/e2e-results"
```

The key advantage over running Claude Code directly in CI: **no arbitrary code execution**. The LLM can only interact with the simulator through the predefined tool set. No `curl`, no `jq`, no shell scripts.
