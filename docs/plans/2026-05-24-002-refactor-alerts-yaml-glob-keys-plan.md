---
title: "refactor: alerts.yaml glob keys + topic-driven matching (Ticket B)"
type: refactor
status: active
date: 2026-05-24
origin: docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md
---

# refactor: alerts.yaml glob keys + topic-driven matching (Ticket B)

## Overview

Migrate `alerts.yaml` from literal `name` keys to event-topic glob keys, using `Aiur.Events.Topic.matches?/2` (built in Ticket A) as the matcher. Refactor `Aiur.Alerts` to look up alert definitions by walking the YAML keys with the glob matcher. Migrate every `Alerts.emit_system/emit_custom` callsite to publish through `Aiur.Events.Exchange` (Ticket A) — the publish path is now the canonical entry point, with alerting as a leaf on top. Wire the authoritative-event-wins rules from the brainstorm: drop `chat.send` (already-removed noise), consolidate `cancelled`/`canceled`, route PR-merge sound to `ticket.*.pr.merged` instead of label flips, route close to `ticket.*.issue.state.changed` instead of `task.done` label.

Depends on Ticket A landing first (`Aiur.Events.Exchange`, `Aiur.Events.Topic`, the new event publishing pipeline).

---

## Problem Frame

Today `Aiur.Alerts` matches alerts by literal name (`Map.get(definitions(), name)` at `elixir/lib/aiur/alerts.ex:29`). Every orchestrator-side alert callsite passes a literal string (`"task.todo"`, `"agent.paused"`, `"chat.open"`). After Ticket A, the system has an event bus with topic-shaped names (`ticket.<id>.agent.paused`, `system.main.branch.push`, etc.), and the brainstorm specifies that `alerts.yaml` becomes a **glob-keyed topic→{message, sound} registry** so a single alert entry can cover all tickets (`"ticket.*.agent.paused"` matches `ticket.42.agent.paused` and `ticket.101.agent.paused`).

The migration is mechanical but cross-cutting: every existing callsite must move from "call `Alerts.emit_system("name")`" to "publish an event whose topic matches an alert entry." The matching layer changes shape; the YAML file shape changes; the callsites change. All three must move together or alert behavior breaks.

The brainstorm also locked an authoritative-event-wins rule: when a tracker-driven label flip and a GitHub-driven state change both signal the same notional event (PR merge, ticket close), alert on the GitHub-authoritative event only. Ticket B applies this rule when authoring the new YAML and removing redundant label-driven alert entries.

(see origin: `docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md`)

---

## Requirements Trace

- R1. `alerts.yaml` keyed by event-topic glob patterns (AMQP `*` and `#` wildcards) instead of literal names
- R2. `Aiur.Alerts.definition_for_topic/1` (renamed from `definition/1`) walks all YAML keys and returns the first matching entry via `Aiur.Events.Topic.matches?/2`; returns nil if no match
- R3. `Aiur.Alerts.emit_system/2` and `emit_custom/3` publish events through `Aiur.Events.Exchange.publish/2`; `Aiur.Alerts` runs its existing sound + IssueLog + PubSub broadcast pipeline only when the published event's topic matches an `alerts.yaml` entry
- R4. Every existing `Alerts.emit_system` literal name (`task.todo`, `task.todo.more_agents`, `task.in-progress`, `task.human-review`, `task.rework`, `task.merging`, `task.done`, `task.cancelled`/`task.canceled`, `agent.paused`, `agent.unpaused`, `agent.more_tokens`, `chat.open`, `chat.send`, `chat.close`, `phase.*`) migrates to its new event topic per the brainstorm's translation table
- R5. Authoritative-event-wins rules applied:
  - `task.merging` retired — sound now fires on `ticket.*.pr.merged`
  - `task.done` retired — sound now fires on `ticket.*.issue.state.changed` (with `to: :closed`)
  - `task.cancelled` / `task.canceled` consolidated into a single entry matching `ticket.*.issue.state.changed` with `state_reason: :not_planned` (GitHub's canonical "cancelled" signal)
  - `chat.send` dropped entirely (already removed in `orchestrator.ex:2136` comment; reflects existing reality)
- R6. `Aiur.Alerts.@system_scopes ["task.", "agent.", "chat."]` literal-prefix block removed — agent-side scope policing now happens in Ticket A's `emit_event` / `emit_alert` tool allowlist validation
- R7. Single `[event:emit:alert]` log row per alert-bearing event (not doubled with separate `[alert]` row) — covered by Ticket A U19 (IssueLog markers); Ticket B verifies the integration
- R8. All existing alert-bearing behavior (sound playback, `❗` propagation, dashboard alert badge, per-issue log presence) preserved for the migrated entries — no operator-facing regression
- R9. Test suite migrated: every `Alerts.emit_system("task.done", …)` / `emit_custom(…)` call in `elixir/test/aiur/alerts_test.exs` + `alerts_broadcast_test.exs` uses the new shape; new tests for glob matching edge cases

**Origin actors:** A1 (operator — hears sounds, sees ❗), A3 (orchestrator — emits lifecycle alerts)
**Origin flows:** F1 (orchestrator detects task state change → fires alert → operator hears sound + sees badge)

---

## Scope Boundaries

- No new event types added — Ticket B only migrates existing alert callsites; new event categories ship in Tickets A and C
- No changes to the agent-side `emit_alert` tool (Ticket A owns it; Ticket B reuses the alert pipeline emit_alert already triggers)
- No dashboard panel changes (Ticket C scope)
- No removal of the existing per-agent `agent:<identifier>` Phoenix.PubSub broadcast — `Aiur.AgentPubSub.broadcast_alert/2` stays; the alert event is broadcast in addition to the event-bus publish (both channels fire to preserve all existing consumers without modification)
- No CODEOWNERS-filtered alerting — alerts are operator-facing only; sanitization (Ticket A) applies to agent-bound delivery, not operator-facing alerts

### Deferred to Follow-Up Work

- Ticket C: dashboard events panel, write-parity verification, startup credential gate, CSRF defense, compile-warning cleanup — independent of Ticket B; can run in parallel after Ticket A lands

---

## Context & Research

### Relevant Code and Patterns

- **Current alerts matching**: `elixir/lib/aiur/alerts.ex` — `definition/1` (line 29) does literal `Map.get`; `normalize_definitions/1` (line 136) builds the map from YAML
- **Ticket A's matcher**: `elixir/lib/aiur/events/topic.ex` (U1 in Ticket A's plan) provides `matches?(pattern, topic) :: boolean()` — the same matcher used by `Aiur.Events.Exchange` for subscription routing
- **Existing emit pipeline**: `Aiur.Alerts.do_emit/3` (line 61) — loads definition, picks sound, writes to `AgentEventLog`, broadcasts via `AgentPubSub`, fires `ObservabilityPubSub.broadcast_update`. The body stays; only the lookup at the front changes
- **System-scope block**: `Aiur.Alerts.@system_scopes ["task.", "agent.", "chat."]` (line 13) blocks agent-side emissions of system-owned prefixes. Removed in Ticket B because agent-side validation now happens in Ticket A's `emit_event` tool allowlist (`progress | decision | blocked | unblocked | attention | attention.resolved | pause.request | custom`) — system-owned prefixes simply aren't in the allowlist
- **Callsite enumeration**:
  - `elixir/lib/aiur/orchestrator.ex:252,258` (handle_info delegate, dynamic name)
  - `elixir/lib/aiur/orchestrator.ex:694` (`task.#{current_state}` — covers todo, in-progress, human-review, rework, merging, done, cancelled)
  - `elixir/lib/aiur/orchestrator.ex:843` (deferred `task.todo` via `Process.send_after`)
  - `elixir/lib/aiur/orchestrator.ex:2172` (`agent.paused`)
  - `elixir/lib/aiur/orchestrator.ex:2180` (`agent.unpaused`)
  - `elixir/lib/aiur/orchestrator.ex:2624,2630` (`task.todo.more_agents`)
  - `elixir/lib/aiur/agent_runner.ex:766` (`Alerts.emit_custom` — agent's `emit_alert` tool dispatch; stays as-is, agent-tool semantics)
  - `elixir/lib/aiur/agent_runner.ex:778` (`agent.more_tokens`)
  - `elixir/lib/aiur_web/live/dashboard_live.ex:543` (`chat.open`)
  - `elixir/lib/aiur_web/live/dashboard_live.ex:555` (`chat.close`)
- **Current `alerts.yaml` entries** (all literal-keyed): `task.todo`, `task.todo.more_agents`, `task.in-progress`, `task.human-review`, `task.rework`, `task.merging`, `task.done`, `task.cancelled`, `task.canceled`, `agent.more_tokens`, `agent.paused`, `agent.unpaused`, `chat.open`, `chat.send`, `chat.close`, `phase.brainstorm.start/end`, `phase.plan.start/end`, `phase.work.start/end`, `phase.review.start/end`
- **Test patterns**: `elixir/test/aiur/alerts_test.exs` exercises every alert path including sound expansion, broadcast assertions, error cases; `alerts_broadcast_test.exs` covers PubSub propagation. Both migrate together with the production code

### Institutional Learnings

- **Ticket A precedents transfer directly** — `Aiur.Events.Topic.matches?/2` is the single source of truth for glob matching; `Aiur.Events.Exchange.publish/2` is the canonical event publish entry. Reuse without modification
- **The "no historical comments" rule** — when removing `@system_scopes`, the `task.cancelled` / `task.canceled` duplicate, or `chat.send`, delete cleanly. No `# was: task.foo` legacy markers; PR description carries the migration narrative
- **Authoritative-event-wins origin context**: the existing `orchestrator.ex:2136` comment already explains why `chat.send` was dropped as noise — the same reasoning extends to label-flip-vs-authoritative-event dedupes (merge sound on `pr.merged` not `agent:merging` label add; close sound on `issue.state.changed` not `agent:done` label add)

### External References

- **AMQP topic semantics** (resolved in Ticket A research): `*` = exactly one segment; `#` = zero or more segments. RabbitMQ tutorial 5 is authoritative
- **No Hex library is a direct fit for AMQP-pattern-keyed YAML config**: `path_glob` and `ex_minimatch` use filesystem-glob semantics (`/`-delimited, `**` not `#`); the `amqp` client doesn't expose its broker-side matcher. Inline the matcher (Ticket A's `Aiur.Events.Topic.matches?/2`)
- **YamlElixir 2.12 returns string-keyed `%{}` maps**: ordering is lost after parse. Confirmed: load-time conversion to `[{pattern, definition}]` list + specificity sort is the right shape
- **Table-driven test pattern** (Palardy template) is the canonical Elixir-community style for matcher dispatch tests. Adopt for the matcher edge-case fixture (`for {name, %{pattern: p, topic: t, expected: e}} <- %{…}, do: …`). Cleaner than `ExParameterized` (no extra dep) and clearer than Elixir 1.19's case-level `:parameterize` for per-row labels
- **Clean break (no `@deprecated` alias) is correct for first-party app code**: Elixir's `@deprecated` policy targets public libraries on Hex; applications are free to rename without shim. Matches Aiur's "no-historical-comments" convention. Confirmed
- **Publish-then-conditionally-alert** has no canonical community name. Closest authoritative reference: Kaszubowski's "A guide to event handling in Elixir" (treat `Events.Exchange.publish/2` as the guaranteed boundary; sound + broadcast as best-effort secondary effects in the same linear pipeline). Mirror the existing `Aiur.AgentPubSub.do_broadcast/2` two-stage pattern (defensive guard + log-and-skip when prerequisite isn't running)

---

## Key Technical Decisions

- **Alert publish flows through the event bus, not around it**: `Alerts.emit_system/2` (and `emit_custom/3`) internally calls `Aiur.Events.Exchange.publish/2` with the right topic, then runs the existing sound+broadcast pipeline if the published topic matches an alerts.yaml entry. This single entry point keeps the event-vs-alert separation clean (every alert is an event; only some events are alerts) without forcing every caller to publish + match separately
- **`Aiur.Alerts` retains its public API surface**: `emit_system(name, opts)` and `emit_custom(name, message, opts)` still take a `name` (now interpreted as the event topic) — callers don't need to learn a new function. The migration is "every callsite now passes a topic-shaped name" not "every callsite calls a different function." Reduces churn and keeps the diff focused
- **Matcher is first-match-wins with specificity-sorted ordering, not YAML-insertion-order**: BEAM maps don't preserve insertion order (`YamlElixir` returns `%{}` so ordering is lost after parse), so "YAML order wins" cannot be the semantic. At load time, convert the YAML to a `[{pattern, definition}]` list and sort by specificity descending: most literal segments first, `*`-bearing patterns next, `#`-bearing patterns last (catch-alls fire only when nothing more specific matches). Deterministic, doesn't rely on parse-order tricks, and matches operator intuition ("the more specific pattern wins")
- **Scoring rule**: `score(pattern) = (count_literal_segments * 100) - (count_star_segments * 10) - (count_hash_segments * 1)`. Higher score = more specific. Ties broken by lexicographic comparison of the pattern itself (stable, deterministic). Documented in a comment in the `Aiur.Alerts` matcher
- **Authoritative-event-wins is enforced in the YAML, not in code**: dropping `task.merging` and `task.done` entries from the YAML achieves the rule without needing a "this alert is shadowed by an authoritative event" runtime check. If a future operator re-adds them, both alerts fire — acceptable, easy to detect in manual testing
- **`chat.send` removal is the cleanup precedent**: the existing comment at `orchestrator.ex:2136` confirms this was already de-noised internally; the YAML key removal completes the cleanup
- **Test migration is in scope, not deferred**: every alerts test moves to new keys in the same commit family. Test suite stays green throughout the migration
- **Per-issue topic naming for tracker-driven events uses the issue identifier from the orchestrator's running set**: `Alerts.emit_system(name, issue: identifier, ...)` constructs `ticket.<identifier>.<surface>.<verb>` for the topic at publish time. The existing `issue:` option is the canonical context (`alerts.ex:111` already extracts identifier from `Issue{} | binary`)

---

## Open Questions

### Resolved During Planning

- **Matcher precedence**: specificity-sorted first-match-wins (literal > `*` > `#`; ties broken lexicographically), not YAML-insertion-order (resolved here per external research: BEAM maps don't preserve insertion order so insertion-order semantics aren't reliable)
- **Where the topic name is built**: `Aiur.Alerts.do_emit/3` constructs the full topic from `name` + `opts[:issue]`; callers stay simple (resolved here)
- **Public API surface preservation**: `emit_system` and `emit_custom` keep their function names and arity (resolved here)
- **Per-issue PubSub broadcast retention**: `AgentPubSub.broadcast_alert/2` stays — existing per-agent consumers (IssueLog, AgentList, opencode SessionWriter alert path) keep working without modification (resolved here)

### Deferred to Implementation

- **Exact glob patterns in the migrated `alerts.yaml`**: the brainstorm gave example patterns (`"ticket.*.pr.merged"`, etc.) but the final YAML is best authored when touching the file. May discover that some patterns need narrowing (e.g., `system.dispatch.*` instead of `system.dispatch.todo_capacity_exceeded`) once all callsites are wired through
- **Whether to add a `Aiur.Alerts.list_matching_topics/0` test/debug helper**: useful for verifying YAML coverage during migration, but may be unnecessary if test coverage is high. Decide during impl
- **Whether to inline the `do_emit/3` body change or extract a `find_matching_definition/1` helper**: cosmetic; one or the other reads clearer when the diff is in front of the implementer
- **YAML comment header explaining first-match-wins ordering rule**: write it during impl when finalizing the YAML

---

## Implementation Units

### Phase 1 — Matcher integration

- [ ] U1. **`Aiur.Alerts` matcher refactor**

**Goal:** Replace `Aiur.Alerts.definition/1`'s literal `Map.get` lookup with topic-glob matching via `Aiur.Events.Topic.matches?/2`. Walk YAML keys in insertion order; return first matching entry; nil on no match.

**Requirements:** R2, R6

**Dependencies:** Ticket A U1 (`Aiur.Events.Topic.matches?/2`) must be merged

**Files:**
- Modify: `elixir/lib/aiur/alerts.ex` (rename `definition/1` → `definition_for_topic/1`; replace lookup body; remove `@system_scopes` block and `system_owned_name?/1`; remove the `emit_custom` arity-3 system-scope guard at line 52)
- Modify: `elixir/lib/aiur/codex/dynamic_tool.ex` (remove the `system_owned_name?` call — agent-side scope is policed by the new `emit_event` tool allowlist from Ticket A)
- Test: `elixir/test/aiur/alerts_test.exs` (revise the literal-name lookup tests to use the new topic-glob semantics; remove `@system_scopes` test cases — coverage moves to Ticket A's `emit_event` tool tests)

**Approach:**
- `normalize_definitions/1` (existing function) converts the YAML map to a `[{pattern, definition}]` list AND sorts by **specificity descending**: `score(pattern) = (literals * 100) - (stars * 10) - (hashes * 1)`; ties broken lexicographically by pattern string. Most-specific patterns matched first
- `definition_for_topic(topic)` walks the sorted list; for each `{pattern, entry}`, calls `Aiur.Events.Topic.matches?(pattern, topic)`; returns the first match's entry
- Returns `nil` on no match — `do_emit/3` already handles `nil` gracefully (no sound, no broadcast — just log if message present)
- The `@system_scopes` literal-prefix gate is gone: agent-side `emit_event` tool from Ticket A enforces the allowlist; agent-side `emit_alert` tool wraps `emit_event` and inherits the same allowlist. Server-side `Alerts` no longer needs the prefix check
- `definition_for_topic/1` carries an `@spec` matching the existing `definition/1` shape (`@spec definition_for_topic(String.t()) :: definition() | nil`) — required by `mix specs.check`

**Patterns to follow:**
- `Aiur.Events.Topic.matches?/2` (from Ticket A U1)
- Existing `do_emit/3` body in `alerts.ex` — the rest of the pipeline stays intact

**Test scenarios:** (adopt the table-driven Palardy `for`-loop pattern for matcher dispatch; see `elixir/test/aiur/opencode/protocol_test.exs` lines 51, 77 for in-repo precedent)
- Happy path: topic `ticket.42.pr.merged` matches YAML key `"ticket.*.pr.merged"` → returns the entry
- Happy path: topic with no matching key returns `nil`
- Happy path: topic matches both `"ticket.*.pr.merged"` (specific) and `"ticket.#"` (catch-all) → returns the specific entry (specificity-sort wins)
- Happy path: topic matches both `"*.42.pr.merged"` and `"ticket.*.pr.merged"` → returns whichever has more literal segments; ties broken lexicographically
- Edge case: empty YAML returns `nil` for any topic
- Edge case: malformed pattern in YAML (e.g., a literal name without dots) treated as direct-match by `Topic.matches?/2`
- Edge case: removed `@system_scopes` guard — `emit_custom` with name `"task.x"` (formerly blocked) now publishes (relying on agent-side allowlist to block at the tool layer, not here)

**Verification:**
- `definition_for_topic/1` returns correct entries for every alerts.yaml v2 pattern
- `do_emit/3` unchanged behavior when an entry matches (sound + broadcast + log) and when none matches (no-op except for log)
- Removing `@system_scopes` does not allow agent tools to fire system alerts (Ticket A's allowlist gates this at the tool entry)

---

### Phase 2 — YAML migration

- [ ] U2. **`alerts.yaml` v2 — glob keys + authoritative-event-wins**

**Goal:** Rewrite `alerts.yaml` from literal name keys to event-topic glob keys. Drop `chat.send`, `task.merging`, `task.done`. Consolidate `task.cancelled`/`task.canceled` into one entry. Add a leading comment documenting first-match-wins ordering.

**Requirements:** R1, R4, R5

**Dependencies:** None (file edit; coordinated with U1 + U3 in the same commit family so behavior stays green)

**Files:**
- Modify: `alerts.yaml`

**Approach:**
- Translation table applied:

| Old key | New topic glob | Notes |
|---|---|---|
| `task.todo` | `ticket.*.issue.label.added.agent.todo` | tracker label-driven |
| `task.todo.more_agents` | `system.dispatch.todo_capacity_exceeded` | orchestrator-emitted |
| `task.in-progress` | `ticket.*.issue.label.added.agent.in-progress` | unchanged sound (none) |
| `task.human-review` | `ticket.*.issue.label.added.agent.human-review` | sound preserved |
| `task.rework` | `ticket.*.issue.label.added.agent.rework` | unchanged sound (none) |
| `task.merging` | **DROPPED** | superseded by `ticket.*.pr.merged` |
| `task.done` | **DROPPED** | superseded by `ticket.*.issue.state.changed` (to closed) |
| `task.cancelled` / `task.canceled` | `ticket.*.issue.state.changed` (with `state_reason: :not_planned`) | consolidated; one entry handles both spellings |
| `agent.more_tokens` | `ticket.*.agent.error.tokens_exhausted` | |
| `agent.paused` | `ticket.*.agent.paused` | |
| `agent.unpaused` | `ticket.*.agent.unpaused` | |
| `chat.open` | `ticket.*.chat.opened` | renamed surface (`opened` not `open`) |
| `chat.send` | **DROPPED** | already-removed noise per `orchestrator.ex:2136` |
| `chat.close` | `ticket.*.chat.closed` | renamed surface |
| `phase.brainstorm.start` | `ticket.*.agent.progress.brainstorm-start` | |
| `phase.brainstorm.end` | `ticket.*.agent.progress.brainstorm-end` | |
| `phase.plan.start` | `ticket.*.agent.progress.plan-start` | |
| `phase.plan.end` | `ticket.*.agent.progress.plan-end` | |
| `phase.work.start` | `ticket.*.agent.progress.work-start` | |
| `phase.work.end` | `ticket.*.agent.progress.work-end` | (no sound — unchanged) |
| `phase.review.start` | `ticket.*.agent.progress.review-start` | |
| `phase.review.end` | `ticket.*.agent.progress.review-end` | |
| *new — authoritative replaces task.merging* | `ticket.*.pr.merged` | sound: `archon-merging-complete.wav` (moved from `task.merging`) |
| *new — authoritative replaces task.done* | `ticket.*.issue.state.changed` (state: closed) | sound: `advisor-upgrade-complete.wav` (moved from `task.done`) |

- Leading comment block documents: first-match-wins ordering rule; AMQP `*`/`#` wildcards; the dropped/consolidated entries (with PR-link reference, but no `# was:` historical comments per repo convention — narrative lives in the commit message and PR description)

**Patterns to follow:**
- Existing `alerts.yaml` shape (top-level `alerts:` map; per-entry `message:` + optional `sound:` list)

**Test scenarios:**
- Test expectation: none — YAML data file, no behavioral logic. Behavioral verification happens in U1 (matcher) and U5 (test suite migration). YAML parsing correctness verified by `Aiur.Alerts.definitions/0` returning the expected map shape.

**Verification:**
- File parses via `YamlElixir.read_from_file/1` without error
- `Aiur.Alerts.definitions/0` returns the expected entries in insertion order
- Visual inspection: every legacy key has either a migration target or is documented as intentionally dropped

---

### Phase 3 — Publish-through-Exchange integration

- [ ] U3. **`Aiur.Alerts` publish-through-Exchange integration**

**Goal:** Modify `Aiur.Alerts.do_emit/3` to publish events through `Aiur.Events.Exchange.publish/2` before running the sound+broadcast pipeline. The published topic is constructed from the `name` argument + `opts[:issue]` context.

**Requirements:** R3, R7

**Dependencies:** U1 (matcher refactor), Ticket A U5 (Exchange), Ticket A U4 (IdGenerator), Ticket A U19 (IssueLog event markers)

**Files:**
- Modify: `elixir/lib/aiur/alerts.ex` (extend `do_emit/3` to construct topic + publish to Exchange first; existing sound/broadcast pipeline runs when matched entry exists)
- Modify: `elixir/lib/aiur/alerts.ex` (the `do_emit/3` topic-construction logic — extract a small `topic_for/2` helper that takes `name` + `opts` and returns `"ticket.<id>.<name>"` or `"system.<name>"` based on whether `:issue` was provided)
- Test: `elixir/test/aiur/alerts_test.exs` (add tests asserting events publish through Exchange even when no matched entry; assert published topic shape; assert `[event:emit:alert]` log row appears via IssueLog integration)

**Approach:**
- New `topic_for(name, opts)`: if `opts[:issue]` present → `"ticket.#{identifier}.#{name}"`; else → `"system.#{name}"`
- `do_emit/3` flow becomes: build topic → publish event via `Aiur.Events.Exchange.publish/2` (this writes `[event:emit]` to IssueLog via Ticket A's marker integration) → look up `definition_for_topic(topic)` → if matched, run existing alert pipeline (sound, broadcast, `[event:emit:alert]` log marker via Ticket A's distinction) → if not matched, just log `[event:emit]` and return
- The published event payload includes `name`, `message`, `selected_sound`, `source: :orchestrator | :agent` (based on whether `emit_system` or `emit_custom` was the entry point), `author: nil`, and the original raw payload
- Existing `AgentPubSub.broadcast_alert/2` call is preserved — alert-bearing events double-broadcast to the per-agent topic so existing consumers (IssueLog alert handler, opencode SessionWriter alert path) keep working without modification

**Patterns to follow:**
- Existing `Aiur.Alerts.do_emit/3` body — augmented, not rewritten
- `Aiur.Events.Exchange.publish/2` API from Ticket A

**Test scenarios:**
- Happy path: `emit_system("agent.paused", issue: identifier)` → publishes `ticket.<id>.agent.paused` event → matched entry → sound + broadcast fires
- Happy path: `emit_system("task.todo.more_agents")` → publishes `system.dispatch.todo_capacity_exceeded` event → matched → sound fires
- Edge case: `emit_system("nonexistent.alert")` → publishes event, no matched entry, no sound/broadcast, only `[event:emit]` log line (no `[event:emit:alert]`)
- Edge case: `emit_custom("my.test", "msg")` from agent context → publishes `ticket.<id>.agent.custom.test` (or similar — exact topic constructed via Ticket A's `emit_event` tool path, not via `Alerts.emit_custom` directly; verify the boundary cleanly)
- Edge case: missing `opts[:issue]` for an orchestrator-side `emit_system` → publishes under `system.<name>`; matched entries with `system.*` patterns fire correctly
- Integration: subscriber to `ticket.*.agent.paused` on Exchange receives event when `emit_system("agent.paused", issue: id)` fires
- Integration: `[event:emit:alert]` log row appears once (single line, not doubled with separate `[alert]`)

**Verification:**
- Every alert-bearing `emit_system` callsite produces both an Exchange-published event AND fires the matched alert
- Every `[alert]` log row in the per-issue log is replaced with `[event:emit:alert]`; no doubled output

---

### Phase 4 — Callsite migration

- [ ] U4. **Orchestrator + pane + agent_runner callsite migration**

**Goal:** Update every `Alerts.emit_system` callsite in `lib/` to pass a topic-shaped name. Apply translation table from U2.

**Requirements:** R4, R5

**Dependencies:** U2 (YAML), U3 (publish integration)

**Pre-step (mandatory — cross-ticket coordination with Ticket A):**
1. Rebase this branch onto post-Ticket-A `main` before any mechanical edit begins.
2. Re-run `grep -n 'Alerts.emit_system\|Alerts.emit_custom' elixir/lib/aiur/orchestrator.ex` and reconcile against the translation table below. Any new callsite that Ticket A's U10 introduced (e.g., for events_etag fetch failures) gets a translation table entry BEFORE proceeding with the migration.
3. Ticket A's U10 plan flags this coupling explicitly — new `Alerts.emit_system` callsites added in U10 should be marked for B's migration in the same PR.

**Files:**
- Modify: `elixir/lib/aiur/orchestrator.ex`:
  - Line 252,258 (handle_info delegate) — `alert_name` is dynamic; callers passing this message now use the new name format already (verify upstream callsites; likely no change at the delegate itself)
  - Line 694 (`task.#{current_state}`) — becomes `issue.label.added.agent.#{current_state}` (the topic constructor in `do_emit/3` will prefix `ticket.<id>.`)
  - Line 843 (`task.todo` deferred) — becomes `issue.label.added.agent.todo`
  - Line 2172 (`agent.paused`) — unchanged name; topic becomes `ticket.<id>.agent.paused`
  - Line 2180 (`agent.unpaused`) — unchanged name
  - Line 2624,2630 (`task.todo.more_agents`) — becomes `dispatch.todo_capacity_exceeded` (no `:issue` opt → `system.*` topic)
- Modify: `elixir/lib/aiur/agent_runner.ex:778` (`agent.more_tokens`) → `agent.error.tokens_exhausted`
- Modify: `elixir/lib/aiur_web/live/dashboard_live.ex`:
  - Line 543 (`chat.open`) → `chat.opened`
  - Line 555 (`chat.close`) → `chat.closed`
- Modify (authoritative-event hooks): wherever `ticket.*.pr.merged` and `ticket.*.issue.state.changed` events are *published* (Ticket A's orchestrator integration U10), confirm those publishes don't ALSO call `Alerts.emit_system("task.merging")` or `Alerts.emit_system("task.done")`. The Ticket A path publishes the authoritative event; the alerts.yaml v2 matched entry fires the sound through the new `do_emit` integration. Old explicit `task.merging`/`task.done` callsites are deleted.

**Approach:**
- Mechanical edits aligned with U2's translation table
- The `task.in-progress` etc. states (`current_state` substitution) require splitting `task.#{current_state}` into the new `issue.label.added.agent.#{current_state}` form — verify all current_state values are covered in the new YAML
- The deferred `Process.send_after` payload at line 843 carries the new name through to the handle_info delegate at line 252
- For `chat.send` removal: there is no current callsite emitting `chat.send` (per `orchestrator.ex:2136` comment, it was already removed) — confirm by grep, document if any latent caller exists

**Patterns to follow:**
- Existing `Alerts.emit_system(name, opts)` shape — only the `name` string changes

**Test scenarios:**
- Happy path: orchestrator emits `agent.paused` (via existing pause flow) → published as `ticket.<id>.agent.paused` → sound fires per alerts.yaml entry
- Happy path: orchestrator emits `dispatch.todo_capacity_exceeded` (existing capacity check) → published as `system.dispatch.todo_capacity_exceeded` → sound fires
- Happy path: dashboard opens chat → `chat.opened` event published; sound fires per matched entry
- Edge case: label flip to `agent:in-progress` → `issue.label.added.agent.in-progress` event publishes; matched entry has no sound (preserves existing silent behavior)
- Edge case: `chat.send` no longer fires anywhere (verified by grep + integration test that opens/closes a chat without seeing a `[event:emit:alert]` for the send action)
- Integration: full e2e — operator pauses an agent, verifies the `agent.paused` sound plays and the per-issue log has `[event:emit:alert]` line

**Verification:**
- No literal `task.*`/`agent.*`/`chat.*`/`phase.*` strings remain in `Alerts.emit_system` callsites in `lib/`
- All operator-facing sound behavior preserved (manual verification via the 3-ticket test from Ticket A)

---

### Phase 5 — Test suite migration

- [ ] U5. **Test suite migration**

**Goal:** Update `elixir/test/aiur/alerts_test.exs` and `alerts_broadcast_test.exs` to use new topic-shaped names. Remove `@system_scopes` test cases (functionality moved to Ticket A). Add new tests for glob matching edge cases.

**Requirements:** R9

**Dependencies:** U1, U2, U3, U4 (the whole stack must work before tests pass)

**Files:**
- Modify: `elixir/test/aiur/alerts_test.exs`
- Modify: `elixir/test/aiur/alerts_broadcast_test.exs`
- Modify: `elixir/test/aiur/codex/dynamic_tool_test.exs` (any `system_owned_name?` assertions move to Ticket A's `emit_event` tool tests — verify Ticket A's test coverage and adjust here if there's gap)

**Approach:**
- Find every `Alerts.emit_system("task.done", …)` style call → replace with new topic + adjusted `opts[:issue]` so the topic construction yields the expected pattern
- Find every `Alerts.emit_custom(…)` test → adjust per the same rules; agent-tool-driven tests stay (covered in Ticket A); orchestrator-driven `emit_custom` tests move to topic shape
- Remove tests of `@system_scopes` rejection (`emit_custom("task.x")` returning `{:error, :system_scope_reserved}` — no longer applicable since gate moved)
- Add new tests:
  - Glob matching: `emit_system("agent.paused", issue: "MT-42")` publishes `ticket.MT-42.agent.paused` matching YAML `"ticket.*.agent.paused"` entry
  - First-match-wins: two patterns matching the same topic, the first in YAML order wins
  - No-match: emitting a topic with no matching YAML entry publishes the event but does not fire sound/broadcast
  - Authoritative-event-wins: `task.merging` no longer fires (was removed from YAML); `ticket.*.pr.merged` does fire (via the same `do_emit` path triggered by Ticket A's orchestrator event publish)

**Patterns to follow:**
- Existing test scaffolding in `alerts_test.exs` — keep `setup` blocks, helper functions, and PubSub assertion patterns

**Test scenarios:**
- The migration tests above
- Edge case: existing `Alerts.emit_system("task.url-sound", …)` test (line 528) — `task.url-sound` doesn't fit new namespace; replace with a representative URL-sound test under the new key shape
- Edge case: behavior parity — for every previously-tested sound playback path, verify equivalent test exists under new key

**Verification:**
- `mise exec -- mix test test/aiur/alerts_test.exs test/aiur/alerts_broadcast_test.exs` is green
- Full test suite is green (no other tests broke from the matcher/YAML/callsite changes)

---

## System-Wide Impact

- **Interaction graph:**
  - `Aiur.Alerts.do_emit/3` now calls into `Aiur.Events.Exchange.publish/2` before its existing sound+broadcast pipeline; all alert-bearing events now appear on the event bus
  - Existing consumers of `agent:<identifier>` Phoenix.PubSub `:alert` messages (IssueLog, opencode SessionWriter alert path) keep working — the dual-broadcast is intentional
  - Orchestrator + dashboard + agent_runner callsites pass new name strings; no other API change
- **Error propagation:**
  - Matcher returns nil cleanly when no YAML entry matches — `do_emit/3` already handles this
  - Exchange publish failures don't crash callers (Ticket A guarantees async fanout)
- **State lifecycle risks:**
  - None — the refactor preserves all existing event state and IssueLog content shape (modulo the single-line `[event:emit:alert]` consolidation, which is desired)
- **API surface parity:**
  - `Aiur.Alerts.emit_system/2` and `emit_custom/3` retain their public function names and arities
  - The `name` argument's interpretation changes (now a topic suffix, not a literal alert name) — callers updated in U4
  - `Aiur.Alerts.definition/1` renamed to `definition_for_topic/1` — internal-only function, no external callers affected
  - `Aiur.Alerts.system_owned_name?/1` removed — was internal; any caller (e.g., `dynamic_tool.ex`) updated in U1
- **Integration coverage:**
  - Existing alert tests verify behavior parity after migration (U5)
  - Ticket A's e2e spec already exercises the published-event-also-alerts path via the 3-ticket scenario
- **Unchanged invariants:**
  - `AgentPubSub.broadcast_alert/2` API and `agent:<identifier>` topic semantics unchanged
  - `AgentEventLog.write/3` API unchanged
  - `ObservabilityPubSub.broadcast_update/0` still fires once per alert (no change)
  - Sound playback path (`maybe_play_sound`, `default_player`) unchanged
  - Per-issue log file format unchanged except for the single-line `[event:emit:alert]` consolidation already specified in Ticket A U19

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Ticket A not yet merged when Ticket B starts | This plan declares Ticket A as a hard prerequisite; ce-work will not begin Ticket B until Ticket A's PR is green |
| Matcher precedence ambiguity (operator expects YAML order to matter) | Document specificity-sort rule in YAML header comment AND in the `Aiur.Alerts` matcher comment; test for both specific-vs-catch-all and lexicographic tiebreak; surface in PR description |
| `mix specs.check` rejects new public functions without `@spec` | All new/renamed public functions (`definition_for_topic/1`, `topic_for/2` helper if extracted) get `@spec` in the same commit; verified by `make all` |
| `Aiur.Alerts` is not in `mix.exs` coverage exemption list — 100% coverage required | Test suite migration in U5 covers every branch (matcher returns nil, matcher returns entry, alerts.yaml glob match, publish-without-match, publish-with-match-with-sound, publish-with-match-without-sound) |
| A latent `emit_system` callsite missed during migration → silent regression (no alert fires) | grep audit in U4 + test suite green requires every translated key to match a YAML entry |
| Authoritative-event-wins regression (both label-flip and PR-merge fire sound for same event) | YAML deletion of redundant entries; manual verification during 3-ticket test |
| Removing `@system_scopes` allows an agent to emit a system-prefixed alert via `Alerts.emit_custom` directly (bypassing the agent tool's allowlist) | Agent code does not call `Alerts.emit_custom` directly — only the `emit_alert` tool dispatches there, and the tool now enforces Ticket A's allowlist. Verify by grep: only `dynamic_tool.ex` calls `Alerts.emit_custom`; that callsite is gated by the new allowlist |

---

## Documentation / Operational Notes

- `alerts.yaml` gains a leading comment block documenting first-match-wins ordering, AMQP wildcards, and the intentional drops (`chat.send`, `task.merging`, `task.done`, `task.cancelled`/`task.canceled` consolidation)
- Operator runbook (if any) for adding new alerts: now means adding an entry to `alerts.yaml` with a topic glob pattern; the matching is automatic
- No migration needed for operator workflow files — `alerts.yaml` is repo-internal, not user-overrideable

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md](../brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md) — specifically the "alerts.yaml v2 — keyed by event topic" and "Refactor of `Aiur.Alerts`" sections
- **Ticket A plan:** [docs/plans/2026-05-24-001-feat-event-system-foundation-plan.md](2026-05-24-001-feat-event-system-foundation-plan.md) — provides `Aiur.Events.Topic`, `Aiur.Events.Exchange`, `Aiur.Events.IdGenerator`, and the `[event:emit:alert]` IssueLog marker
- Related code:
  - `elixir/lib/aiur/alerts.ex` — the module being refactored
  - `alerts.yaml` — the file being migrated
  - `elixir/lib/aiur/orchestrator.ex` — primary callsite owner (`task.*`, `agent.paused/unpaused`, `task.todo.more_agents`)
  - `elixir/lib/aiur/agent_runner.ex` — `agent.more_tokens` + the `Alerts.emit_custom` dispatch for the agent tool
  - `elixir/lib/aiur_web/live/dashboard_live.ex` — `chat.open/close` callsites
  - `elixir/lib/aiur/codex/dynamic_tool.ex` — agent-tool integration; `system_owned_name?` reference being removed
  - `elixir/test/aiur/alerts_test.exs` + `alerts_broadcast_test.exs` — test surface
- AMQP topic-exchange semantics resolved in Ticket A; no external research needed for Ticket B
