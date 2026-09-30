# `web-rest-03`: durable window parser contract at `b4bc11ff`

Static source review only. The observed production incidence is unknown.

## Reachable failure

`ModelAvailability.observe/3` normalizes each `hourly`, `weekly`, or `monthly` map, then writes it to `model-usage.json` (`src/lib/aiur/model_availability.ex:46-68,209-223,367-374`). `normalize_window/1` drops absent fields, so a reset-only bucket persists with no `used` or `limit`; a numeric zero limit persists intact. The writer's unknown-reset logic retains both shapes (`:334-350`). This is an ordinary writer path, not a hand-edited corrupt file.

When a provider is unobserved in the current boot, the Stream Deck projection reads that ledger (`src/lib/aiur_web/streamdeck_projection.ex:235-260,264-317`), and the dashboard run summary does likewise (`src/lib/aiur_web/components/operator_control_center/run_summary_strip.ex:284-291,477-517`). Each `durable_percent_entry/1` takes the same three bucket names and uses a single guarded `Enum.map` clause requiring numeric `used`, numeric `limit`, and `limit > 0` (`streamdeck_projection.ex:319-326`; `run_summary_strip.ex:519-526`). An included reset-only or zero-limit bucket raises `FunctionClauseError`, including when another valid bucket exists. Existing positive-only fixtures (`src/test/aiur_web/streamdeck_projection_test.exs:176-210`; `src/test/aiur_web/components/operator_control_center/run_summary_strip_test.exs:731-778`) cannot hit that branch.

## One small shared contract

The percentage selection is identical on both surfaces: inspect only the three named buckets; for each bucket with numeric `used` and positive numeric `limit`, compute `min(round(used / limit * 100), 100)`; choose the greatest percentage; return `nil` if none qualifies. A total shared helper for **that selection alone** can replace both guarded maps. Use filtering (`flat_map`, `reduce`, or equivalent) so malformed, reset-only, and zero-limit buckets are skipped without hiding a valid sibling. Preserve the current upper cap and rounding. A negative `used` is currently accepted and has no lower clamp; changing that is a separate product decision. Unknown keys have no effect.

Keep each surface's timestamp and presentation decision local. Both parse a `DateTime` or ISO-8601 string, but the deck's `durable_window/2` requires a non-nil `DateTime` before it switches an unknown meter to stale observed (`streamdeck_projection.ex:292-303,328-337`). The run summary attaches a valid percentage even when `observed_at` is absent or invalid (`run_summary_strip.ex:499-517`) and renders its percentage bar (`:245-253`). Sharing a whole observation parser and normalizing those two paths would change behavior. The proposed percentage helper returns only `integer | nil`; each caller keeps its existing `with` and timestamp rule. With no qualifying bucket, the deck retains `state: unknown` and empty windows (`streamdeck_projection.ex:258-260,280-287`); the dashboard takes its existing `Usage not observed` branch (`run_summary_strip.ex:251-255`).

## Failing test contract for an implementation PR

Use a temp workflow path, persist via `ModelAvailability.observe/3`, then invoke each public surface with an unknown meter/card after the write (the two existing durable tests above show the setup). New tests should fail on `b4bc11ff` and pass after the helper replaces both call sites:

1. Persist `weekly: %{reset_at: future_iso}` with no usage figures. Assert `ModelAvailability.load/1` contains a reset-only weekly map. `StreamdeckProjection.provider_meters/2` returns `state: "unknown"` and `windows: %{}`; `render_component(&RunSummaryStrip.run_summary_strip/1, ...)` contains `aria-label="Usage not observed"` and no fabricated percentage. Baseline currently raises at `Enum.map` on both paths.
2. Repeat with `weekly: %{used: 1, limit: 0}`. Assert the same unavailable states. The zero limit must not be divided or represented as 100%.
3. Persist one invalid `hourly` bucket plus valid `weekly: %{used: 81, limit: 100}`. Assert both surfaces show 81%, proving the invalid bucket is skipped rather than rejecting the whole entry. Add two valid buckets to assert the highest percent and 100% upper cap are retained.
4. With a valid percentage but malformed `observed_at` in a temp ledger fixture, assert the current divergence explicitly: deck stays unknown; dashboard keeps the percentage bar. This guards against an overbroad shared observation parser. This fixture is intentionally direct because `observe/3` always writes a valid timestamp.

For each new test, remove only its intended production hunk in a clean isolated worktree and show it fails before restoring and passing, as `AGENTS.md` requires. Do not claim a runtime fix or test pass from this source review.
