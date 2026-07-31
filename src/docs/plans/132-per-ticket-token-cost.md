# Plan — Per-ticket token usage + $ cost (issue #132)

## Goal

Track token usage and USD cost **per ticket**, persisted across agent
restarts and codex/Claude session boundaries, and surface it in the opencode
agent pane (both side-panel-open and side-panel-closed states), refreshing live.

## Key finding

Per-ticket token totals already accumulate in the orchestrator's in-memory
`state.running[issue_id]` (`Aiur.Orchestrator.TokenAccounting`), but that state
is **lost on restart / new session** — the bug this ticket fixes. A dedicated,
persisted per-issue store is the right home. Rich pricing infrastructure already
exists (`Aiur.Usage.PriceTable` with a built-in catalog, `Aiur.Usage.Pricing`),
and usage envelopes are already built per message on the unconditional path via
`Aiur.Usage.Headless.Emitter`.

## Design

Per-issue GenServer `Aiur.Cost.Store`, mirroring `Aiur.Events.SubscriptionStore`
exactly (Registry + DynamicSupervisor, atomic JSON via `Aiur.JsonStore`, keyed by
`Issue.identifier`). Persists to `<logs-root>/<repo>.<id>.cost.json`.

### Accounting model (correct across threads/sessions)

Codex reports **absolute cumulative** token totals per thread
(`thread/tokenUsage/updated.tokenUsage.total`, see `docs/token_accounting.md`).
The store keeps a per-thread high-water map of absolute snapshots:

```
threads: %{ thread_id => %{input, cached_input, output, total, context_window} }
```

- **Cost tokens** = sum of high-water absolutes **across all threads** → survives
  session/thread switches (a new session = a new `thread_id` key; prior keys
  remain in the sum). Priced from the absolute totals (never per-event deltas),
  which sidesteps double-counting entirely.
- **Context** = the *active* thread's latest `total` / `context_window` → the "%
  of context used" for the current conversation window.

### USD computation

Price the accumulated absolute token totals directly via
`PriceTable.lookup/2` (the pattern `GroupedScopes` already uses), catalog from
`PriceTable.default/0`, memoized in state. Dimensions `:input`, `:cached_input`,
`:output`; provider / resolved_model / relationship_revision / context_tier /
cache_write_duration taken from the latest usage envelope. `usd` = Σ component
amounts. If a lookup fails (unknown model/date) cost stays last-known and a
coverage reason is recorded; tokens + context still render.

### Feed

In `AgentRunner.MessageHandler` per-message closure (beside `observe_usage`),
extract a normalized absolute observation via new pure module
`Aiur.Cost.Observation.from_message/3` (thread_id, absolute tokens incl. cached,
context_window, provider/model/pricing dims — reusing `Emitter` envelopes for
pricing dims + `TokenAccounting.Payloads` absolute paths for raw totals). Forward
to `Aiur.Cost.Store.record/2` (fail-closed, off the worker critical path).
`record/2` lazily starts the store (idempotent) so no lifecycle threading is
needed.

### On-disk shape (`<repo>.<id>.cost.json`)

```json
{
  "context": { "tokens": 84300, "limit": 256000, "percent_used": 33 },
  "cost": { "input_tokens": 412300, "output_tokens": 38900,
            "cached_input_tokens": 220100, "usd": 4.27 },
  "provider": "claude", "resolved_model": "claude-opus-4-8",
  "threads": { "<id>": { ... } },
  "last_updated_at": "2026-05-27T19:00:00Z"
}
```

## UI surface

Reuse the existing `Aiur.Events.DebugLog` → `SessionWriter` (side-panel-closed,
persistent row) and `turn_stream` (side-panel-open, live) render paths that
already carry one-line ticker rows. On a cost update, broadcast a compact,
throttled status row (emit when the rounded percent bucket or USD changes, not on
every event, to avoid scrollback spam):

```
Context 84,300 / 256K (33%) · $4.27 spent
```

Both surfaces render from the one broadcast → identical numbers, live refresh.

## Implementation units

1. `Aiur.Cost.Store` GenServer + `Aiur.Cost.StoreSupervisor` + Registry wiring in
   `lib/aiur.ex`; persistence + pricing; **tests** (restart persistence,
   thread-switch keeps total, USD math, percent).
2. `Aiur.Cost.Observation` pure extractor + feed wiring in `MessageHandler`;
   **tests** (codex + claude payload shapes, skip on non-usage messages).
3. UI: cost-row formatter + throttled `DebugLog` broadcast; **tests** on the
   formatter + throttle.

## Risks

- Pricing dimension mismatch (context_tier / cache duration) → cost off. Mitigated
  by taking dims from the resolved envelope and recording coverage reasons.
- UI scrollback spam → mitigated by percent/USD-bucket throttle.
- Double counting → avoided by pricing absolute high-water totals, not deltas.
</content>
</invoke>
