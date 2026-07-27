# simulator-llm-pilot

`simulator-llm-pilot` runs natural-language iOS end-to-end tests against a WordPress or Jetpack app in the iOS Simulator. Tests are written as Markdown, and the model can only interact with the app through a fixed set of sandboxed tools backed by WebDriverAgent, `xcrun simctl`, and the WordPress REST API.

## Why

Traditional XCUITest-style UI tests are often brittle and expensive to maintain. When the UI changes, the test code usually needs to change with it. This project moves the intent of the test into Markdown and lets the model adapt at runtime using the current accessibility tree.

The other problem is CI safety. A general-purpose LLM CLI typically wants broad permissions: arbitrary shell commands, network access, and filesystem writes. `simulator-llm-pilot` sits in the middle and owns those side effects itself. The model can decide what to do next, but it can only act through the narrow interface this tool exposes.

## How it works

```
┌──────────────────────────────────────────────────┐
│  simulator-llm-pilot                             │
│                                                  │
│  ┌───────────┐      ┌───────────────────────┐    │
│  │  Claude   │◄────►│  Tool Executor        │    │
│  │  API      │      │  (sandboxed actions)  │    │
│  │  (Sonnet) │      │                       │    │
│  └───────────┘      │  ┌─────────────────┐  │    │
│                     │  │ WDA HTTP Client │  │    │
│  ┌───────────┐      │  │ simctl wrapper  │  │    │
│  │ Markdown  │      │  │ WP REST API     │  │    │
│  │ test file │      │  └─────────────────┘  │    │
│  └───────────┘      └───────────────────────┘    │
│                                                  │
│  iOS Simulator (booted, app installed)           │
└──────────────────────────────────────────────────┘
```

1. `simulator-llm-pilot` reads a Markdown test file or a directory of `.md` files.
2. It sends the test content and the tool definitions to the Claude API.
3. The model responds with tool calls such as `get_accessibility_tree`, `tap`, and `type_text`.
4. The runner executes those calls through WebDriverAgent, `xcrun simctl`, or the WordPress REST API.
5. Tool results go back to the model, which chooses the next action.
6. The loop continues until the model calls `complete_test` with a pass or fail verdict.
7. The runner still enforces the declared test contract: if verification or cleanup sections exist and the required REST work does not complete successfully, the test is marked failed.

The model cannot execute shell commands, write files, or make arbitrary network requests. Every action goes through the tool executor.

## Available tools

The model has access to exactly these operations:

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
| `rest_api_call` | WordPress REST API call with `purpose=setup`, `verification`, or `cleanup` |
| `wait` | Pause up to 10 seconds |
| `complete_test` | Mark the test as pass or fail |

## Test format

Tests are Markdown files with natural-language sections. The parser uses the top-level title and any `##` sections it finds. Verification and cleanup are optional, but if you declare them, the runner expects the model to execute matching REST API calls successfully.

Example:

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
- **Ruby** >= 3.2
- **WebDriverAgent** built for simulator use (see [Setup](#wda-setup))
- **ANTHROPIC_API_KEY** environment variable
- The app built and installed on a booted simulator

## Installation

Build and install the gem:

```bash
cd simulator-llm-pilot
gem build simulator-llm-pilot.gemspec
gem install ./simulator-llm-pilot-<version>.gem
```

Or run it directly from the repo:

```bash
ruby bin/simulator-llm-pilot run ...
```

Runtime dependencies are Ruby stdlib only.

## Usage

### Run a single test

```bash
simulator-llm-pilot run path/to/create-blank-page.md \
  --app-bundle-id org.wordpress \
  --site-url https://test.example.com \
  --username testuser \
  --app-password "xxxx xxxx xxxx xxxx"
```

### Run a full test suite

```bash
simulator-llm-pilot run path/to/ui-tests/ \
  --app-bundle-id org.wordpress \
  --site-url https://test.example.com \
  --username testuser \
  --app-password "xxxx xxxx xxxx xxxx"
```

When you pass a directory, the runner executes every `.md` file in that directory.

### All options

```
--app-bundle-id ID       App bundle ID (e.g., org.wordpress, com.automattic.jetpack)
--site-url URL           WordPress site URL (or SIMULATOR_LLM_PILOT_SITE_URL env)
--username USER          WordPress username (or SIMULATOR_LLM_PILOT_USERNAME env)
--app-password PASS      WordPress application password (or SIMULATOR_LLM_PILOT_APP_PASSWORD env)
--simulator-udid UDID    Target simulator (auto-detects booted simulator if omitted)
--simulator-name NAME    Boot this simulator if none running
--wda-port PORT          WDA port (default: 8100)
--wda-project PATH       Path to WebDriverAgent.xcodeproj
--results-dir DIR        Output directory for results
--model MODEL            Anthropic model (default: claude-sonnet-4-6)
--max-turns N            Max tool call rounds per test (default: 100)
--timeout SECS           Timeout per test in seconds (default: 600)
--max-context-turns N    Compress accessibility trees older than N turns (default: 20)
--rest-api-prefix PATH   Allowed REST API path prefix (default: /wp-json/)
--rest-api-policy POLICY REST mutation policy (supported: verification-readonly)
--debug                  Enable debug logging
```

The `verification-readonly` policy allows GET, POST, PUT, and DELETE requests
during setup, only GET requests during verification, and GET or DELETE requests
during cleanup. The phases must run in that order and cannot move backward. The
policy applies to every REST path, including batch endpoints. Requests that
violate the policy are rejected before they reach the network.

Run `simulator-llm-pilot run --help` for the CLI help text.

### Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | Yes | Claude API key |
| `SIMULATOR_LLM_PILOT_SITE_URL` | No | WordPress site URL (alternative to `--site-url`) |
| `SIMULATOR_LLM_PILOT_USERNAME` | No | WordPress username (alternative to `--username`) |
| `SIMULATOR_LLM_PILOT_APP_PASSWORD` | No | WordPress app password (alternative to `--app-password`) |

## WDA setup

simulator-llm-pilot uses [WebDriverAgent](https://github.com/appium/WebDriverAgent) to interact with the simulator UI.

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

By default, the runner looks for WDA at `.build/WebDriverAgent/WebDriverAgent.xcodeproj` relative to the working directory. Use `--wda-project` to override that path.

## Output

Results are written to `results/<timestamp>/`:

```
results/2026-03-23-1430/
├── results.md              # Summary with pass/fail for each test
└── screenshots/            # Failure screenshots
    └── create-blank-page-failure-1.png
```

The process exits with status code `0` if all tests pass, or `1` if any test fails or hits an infrastructure error.

## Development

```bash
bundle install
bundle exec rake        # runs tests + rubocop
bundle exec rake test   # tests only
bundle exec rubocop     # lint only
```

## Releasing

1. Add entries under `## Trunk` in `CHANGELOG.md` (subsections: Breaking Changes, New Features, Bug Fixes, Internal Changes).
2. Run `bundle exec rake new_release` — it bumps the version, updates the changelog, pushes a `release/<version>` branch, and opens a PR.
3. Merge the release PR.
4. Create a GitHub Release with a tag matching the version (for example, `0.2.0`). The tag triggers Buildkite to publish the gem to RubyGems.

## CI usage

For Buildkite or other CI systems:

```bash
# Ensure simulator is booted and app is installed
xcrun simctl boot "iPhone 16"
# ... build and install the app ...

# Run tests
simulator-llm-pilot run Tests/AgentTests/ui-tests/ \
  --app-bundle-id org.wordpress \
  --site-url "$TEST_SITE_URL" \
  --username "$TEST_USERNAME" \
  --app-password "$TEST_APP_PASSWORD" \
  --results-dir "$BUILDKITE_ARTIFACT_DIR/e2e-results"
```

Compared with running a general-purpose coding agent directly in CI, the main benefit here is the restricted execution model: the model only interacts with the simulator through the predefined tool set.

## License

MPL-2.0. See [LICENSE](LICENSE).
