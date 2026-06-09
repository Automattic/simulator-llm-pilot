# simulator-llm-pilot CHANGELOG

---

## Trunk

### Breaking Changes

_None_

### New Features

- Cache the system prompt, tool schemas, and conversation prefix on every
  Anthropic request (`cache_control`), so the agent loop re-reads prior turns at
  the cache rate instead of re-billing them at full price each turn. This is the
  dominant cost driver for multi-turn runs.
- Report token usage per test and per run (input, cache write/read, output,
  cache-hit rate) in the console summary and `results.md`, so cost is
  attributable and the effect of caching is measurable.
- Add a `tap_and_wait` tool that taps an element (or coordinates) and returns the
  resulting accessibility tree in one call, with an optional `wait_for` readiness
  marker, so the common tap-then-read step costs one turn instead of two. The
  agent is prompted to prefer it for taps.

### Bug Fixes

_None_

### Internal Changes

- Only compress old accessibility trees once the conversation grows past
  `compress_context_when_chars_exceed`. Below that, history stays append-only so
  prompt caching keeps hitting; above it, compression acts as a context-window
  safety valve for unusually long tests.

## 0.1.0

- Initial release
