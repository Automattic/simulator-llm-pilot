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
- Add concise verification tools — `assert_element_exists`, `assert_element_absent`,
  and `wait_for_element` — that return one-line results, so the model can verify
  UI state without pulling a full accessibility tree (~25KB) per check.
- Add a `tap_collection_cell` tool that taps the Nth cell of a collection/grid view
  by the collection's accessibility identifier (e.g. picking a photo in a media
  picker) without reading the tree to compute cell coordinates.
- Return a short "(Accessibility tree unchanged ...)" marker instead of repeating
  a tree identical to the last one returned, so unchanged ~25KB trees stop
  accumulating in the conversation (their tokens are re-billed on every later turn).
- Add a `--compress-context-over CHARS` CLI option to tune (or disable, with 0)
  the compression threshold, e.g. for A/B-testing cache behavior.
- Include the element's type, label, value, and enabled state in
  `assert_element_exists` and `wait_for_element` results, so a one-line check can
  also answer "what state is the control in" (e.g. a switch value) instead of
  forcing a follow-up full-tree fetch.
- Add a `times` parameter to `tap` and `tap_element` for repeated taps (e.g.
  tapping Undo 10 times) in a single call with a short pause between taps,
  recovering from stale element references mid-sequence — replaces one
  tool-call turn per tap.

### Bug Fixes

- Enforce `assert_element_exists` / `assert_element_absent` at the runner level:
  if a target's most recent assertion is still failing when the test completes,
  a `pass` result is downgraded to `fail` (mirroring the REST verification
  enforcement). The probe pattern — assert, recover, re-assert — is unaffected,
  and the system prompt tells the model to re-assert after recovering.
- `tap_collection_cell` rejects fractional or non-numeric `index` values instead
  of silently coercing them (e.g. `1.9` or `"1foo"` no longer tap cell 1).
- Setting `compress_context_when_chars_exceed` to `0` programmatically now
  disables compression (normalized to `nil` during validation), matching the
  documented CLI behavior, instead of failing validation or meaning
  "always compress".
- `tap_and_wait` no longer deduplicates the returned tree when the tap target
  was not found — the failure message points the model at "the accessibility
  tree below", so that tree is always included in full.
- Tune the system prompt and tool descriptions toward substitution rather than
  addition: assert checks in place of tree fetches, `wait_for_element` instead
  of the `wait` + `get_accessibility_tree` pattern, screenshots only when the
  tree cannot answer the question, and one repeated-tap call instead of a turn
  per tap. (Build 32591 showed the new tools sometimes ran as extra probing on
  top of the usual exploration instead of replacing it.)
- Keep `InfraError` propagating out of repeated taps and element-state
  summaries instead of degrading it into a partial tap count or a missing
  summary — WDA/session failures must reach the executor's infra-error
  accounting (which aborts the test after three consecutive failures). Also
  log the completed/attempted tap count when a tap sequence falls short.

### Internal Changes

- Only compress old accessibility trees once the conversation grows past
  `compress_context_when_chars_exceed`. Below that, history stays append-only so
  prompt caching keeps hitting; above it, compression acts as a context-window
  safety valve for unusually long tests.
- Stop tree compression from thrashing the prompt cache: the default threshold is
  raised from 600K to 2.5M chars (~625K tokens, comfortably inside the 1M-token
  context window), and once compression does trigger, passes after the first run
  in batches instead of rewriting the one or two newly-old messages every turn —
  each per-turn rewrite invalidated the cached suffix and re-billed it at the
  cache-write rate (observed as a 50% cache-hit rate and ~2M cache-write tokens
  on a single tree-heavy test).

## 0.1.0

- Initial release
