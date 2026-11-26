---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
date_created: 2026-10-01
---

# Per-Agent Token and Cache Usage View with Source Scope

## Summary

Add a discoverable per-agent usage view on the dashboard showing provider-reported cumulative token metrics (input, output, cached input, uncached input) with proper scope and observation-age labeling. Keep current context occupancy separate from cumulative usage. Handle unknown/missing values explicitly without conversion to zero. Distinguish between cumulative snapshots and additive deltas in tests.

---

## Problem Frame

Agents consume provider resources (API tokens, cache writes) over the course of a session, attempt, or ticket. Operators currently see real-time context occupancy for active chat panes (current working set), but have no visibility into cumulative usage patterns or cache effectiveness per agent. Codex and Claude provide usage snapshots through their respective reporting mechanisms; the system captures these in `UsageEnvelope` and `UsageAggregate` but does not expose per-agent cumulative views. The gap prevents operators from understanding token efficiency (cached vs. uncached proportion) or diagnosing resource anomalies at agent granularity.

---

## Requirements

1. **New discoverable per-agent usage view** on the dashboard showing cumulative metrics
2. **Provider-reported token dimensions**: input, output, cached input, uncached input, cached proportion where measured
3. **Scope labeling**: clearly identify whether metrics cover current session, attempt, or ticket
4. **Observation age**: label measurement freshness/staleness
5. **Separation of concerns**: current context occupancy (active working set) remains distinct from cumulative usage (lifetime metrics)
6. **Handle unknowns correctly**: missing or unsupported values remain explicit; no conversion to zero
7. **Snapshot semantics**: tests verify cumulative snapshots are not summed or treated as additive deltas
8. **Provider-specific handling**: Claude cache dimensions carry provider-specific semantics (e.g., `cache_write_duration`); Codex reports simple cached/uncached dimensions

---

## Scope Boundaries

### In Scope

- Backend model for per-agent cumulative usage snapshot (distinct from context occupancy)
- Query layer to fetch usage data by agent
- API endpoint or LiveView component to expose usage snapshot
- Frontend component to display per-agent usage with scope and age labels
- Unit tests for snapshot calculation, unknown-handling, and delta/cumulative distinction
- Integration test exercising end-to-end Codex snapshot display

### Deferred to Follow-Up Work

- Time-series trend visualization (storage, querying, UI rendering) — Ben noted cache changes over time are aspirational; defer to separate ticket
- Claude-specific cache metrics display enhancements beyond initial snapshot
- Multi-agent comparison or aggregate usage dashboard

### Out of Scope

- Changes to `UsageEnvelope` or `UsageAggregate` core structures (use as-is)
- Modification of usage ledger or pricing calculation
- Per-request breakdown within an agent session

---

## Key Technical Decisions

1. **Snapshot as a computed view, not stored state** — Query the aggregate at view time rather than denormalizing a separate per-agent usage table. Aggregate already partitions by run/ticket/agent_family/backend; the query layer filters and formats for display without additional storage.

2. **Explicit unknown representation** — Model missing dimensions as `{:unknown, reason}` tuples in the snapshot, not as zero or `nil`. Tests verify this is preserved through formatting and never silently converted.

3. **Scope capture in the snapshot metadata** — Include in the snapshot response which scope (session, attempt, ticket) the metrics cover, plus the observation timestamp and staleness assessment. Display layer consumes this metadata to label the UI.

4. **Separate cumulative from context occupancy in the view model** — The returned usage snapshot explicitly carries `context_occupancy` (current, from agent state) as a distinct field from `cumulative_metrics` (lifetime, from aggregate). UI renders them in separate sections.

5. **Codex thread/tokenUsage as the primary data source** — Codex reports cumulative usage in `thread/tokenUsage/updated` events; these are captured in `UsageEnvelope` with `counter_scope: :thread`. Query that scope when available; fall back to `:attempt` or `:session` when thread-level data is unavailable.

6. **Cached proportion calculation** — Derive `cached_proportion = cached_input / (input + cached_input)` when both dimensions are present and non-zero. Return `{:unknown, :insufficient_data}` if either is missing or if the denominator is zero.

---

## High-Level Technical Design

```
┌─────────────────────────────────────────────────────────────────┐
│                    Dashboard / Agent Detail View                │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Current Context Occupancy (AgentContextPresentation)         ││
│  │  · used_tokens / window_tokens                               ││
│  │  · pressure indicator                                        ││
│  └─────────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Per-Agent Usage View (NEW)                                   ││
│  │  · Cumulative Metrics                                        ││
│  │    - Input tokens (explicit unknown if missing)              ││
│  │    - Output tokens (explicit unknown if missing)             ││
│  │    - Cached input (explicit unknown if missing)              ││
│  │    - Uncached input (derived from input − cached_input)     ││
│  │    - Cached proportion (explicit unknown if insufficient)    ││
│  │  · Scope Labeling                                            ││
│  │    - "Current attempt" / "Current session" / "Current ticket"││
│  │  · Observation Age                                           ││
│  │    - "Updated 2 minutes ago" / "Unknown freshness"           ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
           ↓
    ┌──────────────────┐
    │ Snapshot Service │  AgentUsageSnapshot.current/2
    │ (NEW)            │  · Queries UsageAggregate by agent
    │                  │  · Formats into snapshot struct
    └──────────────────┘
           ↓
    ┌──────────────────────────────────┐
    │ UsageAggregate.query/1           │
    │ (existing, queried with agent ID)│
    │ · Filters cells by agent         │
    │ · Returns raw aggregate data     │
    └──────────────────────────────────┘
```

---

## Implementation Units

### U1. Define AgentUsageSnapshot data structure

**Goal:** Model per-agent cumulative usage with explicit unknown handling.

**Requirements:** N/A (foundational data model)

**Dependencies:** None

**Files:**
- `src/lib/aiur/agent/usage_snapshot.ex` (new)

**Approach:**

Define a struct carrying:
- `agent_id` and `backend`
- `context_occupancy` (current: `{used, capacity}`)
- `cumulative_metrics` map with fields:
  - `input`: `non_neg_integer() | {:unknown, reason}`
  - `output`: `non_neg_integer() | {:unknown, reason}`
  - `cached_input`: `non_neg_integer() | {:unknown, reason}`
  - `cached_proportion`: `float() | {:unknown, reason}`
- `scope`: `:session` | `:attempt` | `:ticket`
- `scope_id`: string (session/attempt/ticket identifier)
- `observed_at`: DateTime
- `freshness_assessment`: `:current` | `:stale` | `:unknown`

Export utility functions:
- `format_token_dimension/1` — format a token value or unknown for display
- `calculate_cached_proportion/3` — derive cached proportion from input/cached_input, returning `{:unknown, reason}` on edge cases
- `summarize_freshness/2` — assess age between observed_at and now

**Patterns to follow:**
- Use the `{:unknown, reason}` pattern from existing `UsageAggregate` where similar representation exists
- Mirror the struct style of `Aiur.CurrentRunOutcomeSnapshot` for consistency

**Test scenarios:**
- Construct snapshot with all dimensions known
- Construct snapshot with mixed known/unknown dimensions
- Format unknown returns literal "—" or "unknown" without attempting zero
- Cached proportion calculation with zero input returns `{:unknown, :zero_input}`
- Cached proportion calculation with missing cached_input returns `{:unknown, :missing_cached_input}`
- Freshness assessment: ` 5min-old → ":current"`, `65min-old → ":stale"`, `nil observed_at → ":unknown"`
- Snapshot struct validates no zero conversion happens during construction

---

### U2. Implement AgentUsageSnapshot query service

**Goal:** Fetch and assemble per-agent cumulative usage from UsageAggregate.

**Requirements:** U1

**Dependencies:** U1

**Files:**
- `src/lib/aiur/agent/usage_snapshot_service.ex` (new)

**Approach:**

Create a module with function:

```
current(agent_id, opts \\ [])
  → {:ok, snapshot} | {:error, reason}
```

Logic:
1. Look up the agent's active session/attempt from agent state (e.g., from `Aiur.AgentQueue` or existing agent supervisor)
2. Query `UsageAggregate.query(%{tickets: [tracker_id], runs: [run_id]})` to get aggregate cells
3. Extract cells matching the agent's backend and agent_family
4. Assemble `AgentUsageSnapshot` struct:
   - Read `input`, `output`, `cached_input` from cells where available
   - Compute `uncached_input = input - cached_input` when both present, else `{:unknown, reason}`
   - Compute `cached_proportion` via `AgentUsageSnapshot.calculate_cached_proportion/3`
   - Determine scope from the source of the cell (thread/attempt/session)
   - Check cell `ingested_at` timestamp and assess freshness
5. Return snapshot or error if no cells found / unable to fetch aggregate

**Patterns to follow:**
- Query shape mirrors `Usage.GroupedScopes` boundary API (scoped queries)
- Error handling follows `Aiur.UsageAggregate` pattern (return error tuples, not exceptions)

**Test scenarios:**
- Query with agent_id that has no usage cells → `{:error, :no_usage_data}`
- Query with agent_id having Codex `thread/tokenUsage` cells → returns snapshot with scope `:thread`
- Query with multiple cells (different counter scopes) → prefers thread-level, falls back to attempt
- Snapshot unknown dimensions remain `{:unknown, ...}`, never zeroed
- Freshness assessment: cells < 5 min old → `:current`, > 1 hour → `:stale`
- Concurrent calls to current/2 do not cause race conditions (read-only aggregate)

---

### U3. Create LiveView component for per-agent usage display

**Goal:** Render the per-agent usage snapshot on the agent detail view.

**Requirements:** U1, U2

**Dependencies:** U1, U2

**Files:**
- `src/lib/aiur_web/components/agent_usage_component.ex` (new)

**Approach:**

Create a function component (no Hooks, pure render):

```elixir
def agent_usage_snapshot(assigns) do
  # assigns: snapshot (AgentUsageSnapshot), agent (Aiur.AgentQueueItem), etc.
  # Render two sections:
  #   1. Current Context (using AgentContextPresentation)
  #   2. Cumulative Usage (if snapshot available)
end
```

Render:
- Section header "Agent Usage"
- Current context subsection (reuse `AgentContextPresentation.label/1`)
- Cumulative metrics subsection with table or list:
  - Input tokens
  - Output tokens
  - Cached input tokens
  - Uncached input tokens (derived)
  - Cached proportion (%)
  - Each row shows value or "—" (via helper) with tooltip on hover for "Unknown" reasons
- Scope line: "Metrics cover: current session / attempt / ticket"
- Observation age line: "Updated 5 min ago / Unknown freshness"
- Error state: "Usage data unavailable" if query fails

**Patterns to follow:**
- Use Aiur's existing Tailwind / component patterns (check `AiurWeb.Components.*`)
- Mirror the layout of `UsageSummaryPresenter` or similar existing usage panels
- No data-loading Hooks; LiveView property updates fetch snapshot on assign change

**Test scenarios:**
- Component renders with snapshot present and all dimensions known
- Component renders with mixed known/unknown dimensions (unknowns show "—")
- Scope label matches snapshot.scope_id + scope
- Age assessment matches snapshot.freshness_assessment and observed_at
- Error message displays when snapshot is `{:error, reason}`
- Component gracefully handles `snapshot: nil` (doesn't render usage section)

---

### U4. Wire usage snapshot into agent detail view

**Goal:** Integrate per-agent usage component into the existing dashboard agent detail or modal.

**Requirements:** U1, U2, U3

**Dependencies:** U1, U2, U3

**Files:**
- `src/lib/aiur_web/live/dashboard_live.ex` (modify)
- `src/lib/aiur_web/pages/agent_detail_page.ex` or equivalent (modify if exists)

**Approach:**

Identify where agent detail is rendered in the dashboard (likely in `DashboardLive` or a dedicated agent-detail component).

1. On agent selection or mount of agent detail, call `AgentUsageSnapshotService.current(agent_id)`
2. Pass resulting snapshot to `agent_usage_snapshot/1` component
3. Subscribe to usage update broadcasts if the dashboard has a refresh cycle
4. Re-fetch snapshot on periodic refresh or on explicit user action

If a dedicated agent-detail modal or drawer exists, insert the usage component above or below the current context occupancy display.

**Patterns to follow:**
- Follow existing `DashboardLive` subscription patterns (e.g., `AgentPubSub`, `UsageAggregate.subscribe()`)
- Reuse existing refresh intervals if dashboard already polls agent data

**Test scenarios:**
- Agent detail loads with snapshot populated
- Snapshot updates when agent usage changes (integration test)
- Stale snapshot is displayed with appropriate age label
- Error in fetching snapshot does not break agent detail rendering

---

### U5. Add tests for snapshot calculation and unknown handling

**Goal:** Verify snapshot semantics: unknown preservation, delta vs. cumulative distinction, no zero-conversion.

**Requirements:** U1, U2

**Dependencies:** U1, U2

**Files:**
- `src/test/aiur/agent/usage_snapshot_test.exs` (new)
- `src/test/aiur/agent/usage_snapshot_service_test.exs` (new)

**Approach:**

**Snapshot calculation tests (usage_snapshot_test.exs):**
- Test `calculate_cached_proportion/3` with various input combinations:
  - Both known, non-zero → returns float
  - Known zero input → `{:unknown, :zero_input}`
  - Known zero cached_input → returns 0.0
  - Missing input → `{:unknown, :missing_input}`
  - Missing cached_input → `{:unknown, :missing_cached_input}`
- Test `format_token_dimension/1`:
  - Known integer → formatted string
  - `{:unknown, _}` → "—" string
  - Negative integers → error or special handling
- Test freshness assessment:
  - 0-5 min old → `:current`
  - 5-60 min old → `:stale`
  - > 60 min → `:stale`
  - Nil observed_at → `:unknown`

**Snapshot service tests (usage_snapshot_service_test.exs):**
- Mock `UsageAggregate.query/1` to return test cells
- Test snapshot assembly with all dimensions present
- Test snapshot with Codex `thread/tokenUsage` (scope `:thread`)
- Test snapshot with `attempt`-scoped data
- Test snapshot with mixed known/unknown cells → unknowns propagate, no zero-filling
- **Critical mutation test**: Remove a calculation line that converts `{:unknown, _}` to `0`; test must fail. Verify test fails. Restore line. → Test must pass. Rationale: demonstrate test catches silent zero-conversion bugs.
- Test that overlapping deltas (e.g., reasoning_output ⊂ output) are not summed
- Test error cases: no cells for agent, query fails, agent_id invalid

---

### U6. Integration test: end-to-end Codex usage display

**Goal:** Verify that a running agent's Codex usage snapshot appears correctly on the dashboard.

**Requirements:** U1, U2, U3, U4, U5

**Dependencies:** U1, U2, U3, U4, U5

**Files:**
- `src/test/aiur/agent/usage_snapshot_integration_test.exs` (new)

**Approach:**

Set up a minimal test agent session:
1. Mock an agent running against Codex
2. Inject a synthetic `UsageEnvelope` with `thread/tokenUsage` data into `UsageLedger`
3. Allow `UsageAggregate` to project it
4. Call `AgentUsageSnapshotService.current/2`
5. Verify snapshot returns expected dimensions
6. Verify snapshot scope is `:thread`
7. Render agent detail with usage component and inspect HTML output
8. Confirm all token dimensions appear in the rendered output
9. Confirm unknowns render as "—"
10. Confirm scope and age labels are present

**Test scenarios:**
- Codex agent with complete usage metrics → all dimensions displayed
- Codex agent with partial metrics → unknowns shown, no gaps in UI
- Age assessment: recent injection → "current", stale injection → "stale"

---

## Verification Contract

1. **Unit tests pass**: `src/test/aiur/agent/usage_snapshot_test.exs`, `usage_snapshot_service_test.exs` → all tests green, mutation test confirms unknown-handling.
2. **Integration test passes**: End-to-end Codex snapshot display verified.
3. **Dashboard smoke test**: Agent detail loads without errors; usage component is discoverable (either always visible or accessible via toggle/drawer).
4. **Snapshot data integrity**: Manually verify that a running agent's snapshot reflects its actual token consumption (via logs or debug output).

---

## Definition of Done

- All tests pass locally: `cd src && mix test --include integration`
- Code compiles without warnings: `cd src && mix compile --warnings-as-errors`
- Formatting is correct: `cd src && mix format && git diff --exit-code`
- Agent detail or modal renders agent usage component without errors
- Unknown token dimensions never display as `0`, always as `"—"` or equivalent
- Scope label and observation age are visible in the rendered component
- No changes to `UsageEnvelope` or `UsageAggregate` core structures; all work layers on top of existing APIs

---

## Sources & Research

- `Aiur.UsageEnvelope` — raw usage measurement contract
- `Aiur.UsageAggregate` — crash-safe aggregate projection
- `Aiur.Usage.GroupedScopes` — scoped query layer (reference for formatting)
- `Aiur.AgentContextPresentation` — existing context occupancy formatting (pattern reference)
- `#2874` — prior related work (context only; this plan is standalone)
- Codebase patterns: `Aiur.CurrentRunOutcomeSnapshot` (similar snapshot struct), `AiurWeb.Components.*` (component patterns)
