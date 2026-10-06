---
ticket_id: MP-E2-C2-T02
feature_id: MP-E2
chunk_id: MP-E2-C2
bucket: 2-platform
title: Durable routing facts and the human-needed event
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C1-T01, MP-E2-C1-T03]
prior_units: [U6]
prior_boundaries: [DEC #27]
prior_features: [MP-R2 (MP-R2-C5-T01 catalog, RC-08), MP-N4/N5 (consumers)]
prior_findings: [RC-08, contract §4, §5, §8]
size_owner: "DECISIONS (decision_store.ex: one public fn + one handle_call; decision_event.ex / decision_projection.ex: list extension only)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C2-T02 — Durable routing facts and the `human_needed` event

## Identity and outcome

- Bucket 2, MP-E2, chunk C2.
- **User value:** "this Command now needs you" becomes a durable, once-only fact that
  notifications (N4/N5) and counts (N3) can trust across restarts.
- **Deliverable:**
  1. Fact types `routed`, `escalated`, `human_needed`, `executor_acknowledged` in
     `Aiur.Commands.EventData` / `Aiur.Commands.Projection` (C1-T01 seams).
  2. Projected fields `route_policy`, `route_state`, `routed_at`, `human_visible_at`,
     `escalations`, `executor_acknowledged_at` on `Aiur.Decision` (optional, default nil/[]).
  3. One store entry point `DecisionStore.record_command_fact(decision_id, type, data, opts)`.
  4. Slugs `routed`, `escalated`, `human-needed`, `executor-acknowledged` published via
     `Aiur.Commands.Topics` (C1-T03); public serializers (C1-T04) gain the fields.
- **Non-goals:** deciding when to write them (C2-T03, C2-T04); notification transport.

## Dependencies and blockers

- Blocked by **DESIGN-E2**; predecessors C1-T01 (seams), C1-T03 (topics).
- **RC-08:** `ticket.<id>.agent.decision.human-needed` and `executor.decision.human-needed`
  are registered by MP-R2-C5-T01's catalog (journaled, exported, refs
  `{decision_id, decision_version}`, attrs `{short_label, requester_kind, blocking,
  urgency, cause}`). If MP-R2-C5-T01 has landed, this PR adds/verifies the two entries
  (the catalog test fails otherwise); if not, nothing to register — the topics live in
  the DecisionStore-owned namespace (`events-and-replay.md` §9) and R2-C5 registers them.
- May run concurrently with C2-T01.

## Verified starting point (`45a290e3`)

- `decision_store.ex:2471-2505` `build_and_persist_event/5` (reserve id → build → validate
  transition → append → update state → notify); `lifecycle_version/2` `:2532-2546`
  (`%{actor: _}` and `%{reason_class: _}` map to `decision.version`).
- `decision_store.ex:892-898` pattern for a writable-guarded `handle_call`.
- `decision_event.ex:310-316` (`executor_escalated` data shape, executor actor required).
- `decision_projection.ex:313-317` (status-neutral transition precedent).

## Chosen design

Event data (all carry `decision_version` = current version; status-neutral):

| Type | `data` | Projection effect | Accept only when |
| --- | --- | --- | --- |
| `routed` | `%{policy, state, cause \| nil, at, actor: %{kind: :system, id: "routing"}}` | sets `route_policy`, `route_state`, `routed_at = at`; `human_visible_at ||= at` if state ≠ with_executor | status ∈ open/deferred (re-route after defer allowed) |
| `escalated` | `%{cause, at, detail ≤ 200, actor}` | `route_state = :with_human`; append `{cause, at, detail}` to `escalations`; `human_visible_at ||= at` | `route_state == :with_executor`; same `{version, cause}` not already present (else `:duplicate`) |
| `human_needed` | `%{cause, at, short_label, requester_kind, blocking, urgency}` | none besides audit; asserts `human_visible_at` set | no prior `human_needed` for this `decision_id` (once per Command) |
| `executor_acknowledged` | `%{executor_id, via: :explicit \| :answer \| :escalate \| :moot \| :supersede, at}` | `executor_acknowledged_at ||= at` | first only (later = `:duplicate`) |

- `record_command_fact/4` returns `{:ok, %{status: :accepted \| :duplicate, decision: d}}`
  or `{:error, reason}`; read-only store → `{:error, :store_read_only}` (existing pattern).
- **`human_needed` emission rule** (the single place): `Aiur.Commands.Routing` (C2-T03)
  writes `human_needed` right after a `routed`/`escalated` fact that set
  `human_visible_at` for the first time. The projection refuses a second one, so a
  restart replay or a retry cannot double-notify (N4 dedup key `cmd:<id>:needs_you`,
  notification contract A-E2-1).
- `human_needed` payload carries **no question text** (contract §8).
- Topics via `Topics.lifecycle/2`: worker `ticket.<id>.agent.decision.human-needed`,
  executor `executor.decision.human-needed`.

## Implementation steps

1. `commands/event_data.ex`, `commands/projection.ex`: four types (≈120 lines added).
2. `decision.ex`: six optional fields.
3. `decision_store.ex`: `@spec record_command_fact(String.t(), atom(), map(), keyword())`
   public fn + writable/readonly `handle_call` pair delegating to
   `build_and_persist_event/5`; `lifecycle_slug/1` four clauses.
4. C1-T04 serializers: add the six fields (+ `escalations` as list of maps).
5. If present, MP-R2 catalog entries (RC-08).

## Non-happy paths

- Append failure: `{:error, {:append_failed, _}}`; caller (Routing) retries next tick —
  idempotency rules make retries safe.
- Racing writers: only Routing writes these (plus C2-T04 for ack via the same fn); the
  GenServer serializes.
- Answer arrives between Routing's read and its `escalated` write: the transition accepts
  only `with_executor` + no answer, so it returns `{:error, {:invalid_transition, _}}`;
  Routing treats that as "nothing to do".
- Rollback: older binary skips the four types (Unrecognized) — routing state is lost,
  today's behaviour returns (everything visible to the human, no notifications).

## Compatibility and rollout

- Additive. No config. No producer until C2-T03 (so merging this alone is inert).

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/commands/projection_test.exs test/aiur/decision_store_test.exs test/aiur/decision_projection_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "routed with_executor then escalated sets with_human and human_visible_at" | fields as table; `escalations` length 1 | projection clauses |
| "escalated twice with same cause and version is duplicate" | second returns `:duplicate`; one log line | dedup check |
| "human_needed is accepted once per Command" | second `{:ok, %{status: :duplicate}}`, one `human-needed` publish | once-guard |
| "human_needed after restart replay is still refused" | restart store from log, write again → duplicate | guard reads projected state, not memory |
| "escalated after answer is refused" | `{:error, {:invalid_transition, _}}` | `with_executor`+no-answer guard |
| "human-needed payload has no question text" | captured publish payload has no `question`, `options`, `context` keys | payload builder |
| "executor topic for executor requester" | `executor.decision.human-needed` | Topics use |

Mutation check per row (worktree; revert only the named hunk).

## Completion and handoff

- [ ] Four fact types, six fields, one store entry point, slugs, serializers.
- [ ] RC-08 catalog entries if MP-R2-C5 exists.
- Docs: `concepts/commands.md` lifecycle table is updated in C8-T01 (not here).
- Dependents: C2-T03, C2-T04, C4-T04 (`native_released` uses the same entry point),
  C6-T02, C7-T01/T02, MP-N4/N5.
