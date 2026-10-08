---
ticket_id: MP-E2-C1-T01
feature_id: MP-E2
chunk_id: MP-E2-C1
bucket: 2-platform
title: Persist v2 Command attributes in a request_attributed event
status: blocked
blocked_by: [DESIGN-E2, MP-R1-C11-T03]
prior_units: [U6, U8]
prior_boundaries: [DEC #27]
prior_features: [MP-R1 (identity contract, session_ref)]
prior_findings: [baseline § E2, MP-E2 plan §1.1, R-Q4 (answered here)]
size_owner: "DECISIONS (decision_store.ex 4,826; decision_projection.ex 1,039; decision_event.ex 1,057) — one delegating clause per file only"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C1-T01 — Persist v2 Command attributes in a `request_attributed` event

## Identity and outcome

- Bucket 2, MP-E2 (Command capture and escalation), chunk C1 (model v2).
- **User value:** a Command can say who asked (worker or Executor), how it was raised, and
  which native request it holds, without risking the store on rollback. Every later
  MP-E2 ticket reads these fields.
- **Deliverable:**
  1. `Aiur.Decision` gains optional fields `requester`, `origin`, `native`, `questions`,
     `short_label` (defaults: `nil` / `[]`), plus read helpers in a new
     `Aiur.Commands.Requester` (`kind/1`, `worker_ticket/1`, `executor?/1`).
  2. A new lifecycle event type `request_attributed`, validated by a new
     `Aiur.Commands.EventData` and projected by a new `Aiur.Commands.Projection`.
  3. `DecisionStore.request/4` and `project_attention/4` accept trusted
     `opts[:requester]`, `opts[:origin]`, `opts[:native]`, `opts[:questions]` and append
     `request_attributed` right after `requested` when any is set.
  4. The reserved ticket identifier `"executor"` (contract §2): rejected for worker
     requests; Executor Commands exempt from `DecisionExpiry`.
- **Non-goals:** validation of `questions[]` content and `short_label` derivation (C1-T02);
  topics (C1-T03); read surfaces (C1-T04); any creator of Executor or native Commands
  (C4, C6); routing fields (C2-T02).

## Dependencies and blockers

- **MP-R1-C11-T03** (final plan refresh after the refactor): enforces "refactor before
  features" (D1, RC-35). Re-read this ticket's paths against the refreshed plan before starting.
- Blocked by **DESIGN-E2** (pack rule: every implementation ticket waits on its gate;
  DESIGN-E2's header allows backend-only C1 to proceed once the coordinator relaxes it).
- Predecessors: none in MP-E2. Cross-feature: MP-R1 identity contract for the
  `session_ref` string (`contracts/identity-and-capabilities.md:101`); if MP-R1 has not
  landed, store `session_ref: nil`.
- Contract: [command-request-and-resolution.md](../../../contracts/command-request-and-resolution.md) §2, §3, §11.
- May run concurrently with C1-T02 (different files) and C3-T01.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/decision.ex:107-192` struct; `:152-167` `@enforce_keys` includes
  `:ticket`; `:150` `@schema_version 1`.
- `src/lib/aiur/decision_event.ex:35-67` `@types`; `:121-127` `new/5`; `:254-418`
  `normalize_data/5`, catch-all `{:error, {:event_data, :invalid}}` at `:418`;
  `:167-193` unknown named types decode to `Aiur.DecisionEvent.Unrecognized`.
- `src/lib/aiur/decision_projection.ex:158` `apply_record(_, %Unrecognized{})` is identity;
  `:47-86` `decode_request_record/2` re-validates the snapshot and compares
  `content_hash`; `:48` requires a `ticket` map. Transitions start at `:276`.
- `src/lib/aiur/decision_store.ex:154-160` `request/4`; `:2161-2168` `handle_request/3`;
  `:2426-2460` `persist_and_notify/3` (single `requested` append, then `notify/3`);
  `:2471-2505` `build_and_persist_event/5` / `build_and_append_event/5`.
- Callers that create Commands: `agent_runner/tool_executor.ex:568-660`
  (`request_decision/5`, `trusted_source/1` at `:844-850`), and the attention projection
  `decision_store.ex:2170-2200`.
- `src/lib/aiur/decision_validation.ex:440-456` `normalize_ticket/1` (any bounded
  non-empty identifier, so `"executor"` is accepted today).
- `src/lib/aiur/decision_expiry.ex:112-117` `expired_candidate?/4` keys on
  `decision.ticket.identifier`.
- Tests: `src/test/aiur/decision_store_test.exs` (incl. `:4440-4474` future event
  retention), `decision_projection_test.exs:937-967`, `decision_expiry_test.exs`.

## Chosen design

- **Why an event and not snapshot fields:** an older binary recomputes the `requested`
  content hash from the fields it knows (`decision_projection.ex:47-86`); extra fields
  would mismatch and latch the store read-only (`decision_store.ex:13-17`). A new event type
  is retained and skipped by older binaries (`decision_event.ex:167-193`). The `requested`
  record therefore stays byte-identical to v1.
- **Event `request_attributed`** — `decision_version` = the request version; `data`:

  ```elixir
  %{requester: %{kind: :worker | :executor, ticket: String.t() | nil,
                 session_ref: String.t() | nil, executor_id: String.t() | nil,
                 harness: String.t() | nil},
    origin: :emit_event | :attention | :native_question | :executor_cli | :supervisor_api,
    native: nil | %{harness: :codex | :claude, native_ref: String.t(), call_id: String.t() | nil,
                    turn_id: String.t() | nil, question_ids: [String.t()],
                    hold: :in_band | :deferred | :released},
    questions: [map()],          # shape validated by C1-T02; [] here
    short_label: String.t() | nil}
  ```

  Validation in `Aiur.Commands.EventData.normalize(:request_attributed, raw)`: enums
  closed, strings bounded (identity 256, label 40), unknown keys dropped. Projection:
  `Aiur.Commands.Projection.apply(decision, event)` copies the fields; a second
  `request_attributed` for the same version is a no-op (idempotent replay).
- **Defaults when the event is absent:** `Requester.kind/1` → `:worker`; `origin` →
  `:attention` if `legacy_attention` is set, else `:emit_event`.
- **Sentinel:** `Aiur.Commands.Requester.executor_ticket_identifier/0` = `"executor"`.
  Validation rejects it unless `opts[:requester].kind == :executor`
  (`{:decision_invalid, {:ticket_identifier, :reserved}}`).
- **Store write:** inside the same `handle_call`, after the `requested` append succeeds,
  append `request_attributed` via `build_and_append_event/5`; then notify once. A failed
  second append logs `phase=request_attribute_append_failed` and still replies `:ok`
  (the Command exists; defaults apply; invariant: never lose the Command for its
  attributes).
- **Invariants:** `requested.content_hash` unchanged by attributes; `request_attributed`
  never changes `decision_status` or `delivery_status`.

## Implementation steps

1. PROPOSED `src/lib/aiur/commands/requester.ex` — helpers + sentinel (≈60 lines).
2. PROPOSED `src/lib/aiur/commands/event_data.ex` — `fact_types/0` (starts as
   `[:request_attributed]`; C2/C4/C6 extend), `normalize/2`, `to_json_safe/2`.
3. PROPOSED `src/lib/aiur/commands/projection.ex` — `apply/2` per fact type.
4. `decision.ex`: add the five optional struct fields with defaults (no `@enforce_keys`
   change); document them in the moduledoc.
5. `decision_event.ex`: append `Aiur.Commands.EventData.fact_types()` to `@types`; one
   clause `defp normalize_data(type, raw, _, _, _) when type in @command_fact_types, do:
   Aiur.Commands.EventData.normalize(type, raw)`; JSON encode via the same module.
6. `decision_projection.ex`: one `transition/2` clause delegating to
   `Aiur.Commands.Projection.apply/2` for `@command_fact_types`.
7. `decision_store.ex`: in `persist_and_notify/3` take the attributes from the request opts
   (threaded as `{decision, attrs}`), append the second event when attrs are non-empty.
   `request/4` and `project_attention/4` pass `opts[:requester|:origin|:native|:questions]`
   through unchanged.
8. `decision_validation.ex`: reserved-identifier check in `normalize_ticket/1` path.
9. `decision_expiry.ex`: `expired_candidate?/4` returns false when
   `Requester.executor?(decision)`.
10. `lifecycle_slug/1` gains `request_attributed -> "request-attributed"` (C1-T03 owns the
    topic helper; this ticket adds only the slug).

## Non-happy paths

- Second append fails (disk full, `:event_id_not_durable`): Command accepted with defaults;
  log + one alert `decision.attributes.append_failed` (no content). A native Command
  without attributes cannot be replied in-band; delivery falls back to a message (§7.1).
- Replay of `request_attributed` before its `requested` (corrupt order): `fetch_current`
  returns `:decision_not_found` → existing corruption path (fail closed), unchanged.
- Rollback to a pre-ticket binary: events skipped; Commands show as v1. An Executor
  Command shows ticket `executor` and may expire after 300 s (release note).
- Concurrency: the GenServer serializes both appends; no interleaving.

## Compatibility and rollout

- No config. No migration: existing logs have no new events and project with defaults.
- Wire: additive event type; `requested` unchanged. Rollback safe (contract §11).
- Feature gate: none needed — no producer sets attributes until C4/C6.

## Verification

Commands (TKD-19):

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/commands/event_data_test.exs test/aiur/commands/projection_test.exs \
  test/aiur/decision_store_test.exs test/aiur/decision_projection_test.exs \
  test/aiur/decision_expiry_test.exs test/aiur/decision_validation_test.exs
env -C src mix compile --warnings-as-errors && env -C src mix format --check-formatted && env -C src mix lint
```

| Test (PROPOSED name) | Expected | Fails without |
| --- | --- | --- |
| `decision_store_test` "request with requester opts appends request_attributed after requested" | log has 2 lines in order; `get/1` returns `requester.kind == :executor` | step 7 append |
| `decision_store_test` "requested snapshot hash is identical with and without attributes" | same `content_hash` for the same payload | step 7 (if attrs leaked into the snapshot) |
| `decision_projection_test` "request_attributed envelope decodes as Unrecognized when the type is unknown" | build the JSON with `to_json_safe`, rename nothing, call `Unrecognized.decode(raw, "request_attributed")` → `{:ok, _}` (proves the envelope an old binary checks) | step 5 encoding |
| `decision_store_test` "store restarts and replays request_attributed" | after restart fields equal | step 6 projection clause |
| `decision_store_test` "attribute append failure keeps the Command" | inject `event_id_reserver` failing on 2nd call; reply `{:ok, _}`, `requester` defaults to worker | step 7 failure branch |
| `decision_validation_test` "worker request with ticket executor is rejected" | `{:decision_invalid, {:ticket_identifier, :reserved}}` | step 8 |
| `decision_expiry_test` "executor-originated Command is not expired" | open Executor Command older than grace is untouched | step 9 |
| `commands/event_data_test` table | invalid enum / overlong label rejected; unknown keys dropped | step 2 |

Mutation check: for each row, revert the named hunk in a worktree, confirm
`git status --porcelain` shows only that revert, run the test, see it fail; restore.
Manual: n/a — no surface reads the fields yet (C1-T04 adds them).

## Completion and handoff

- [ ] Five fields, helpers, event type, one clause each in event/projection/store.
- [ ] `requested` bytes unchanged (test).
- [ ] Tests above fail without their hunks.
- Docs: none (no operator-visible change); C8-T01 documents the model.
- Dependents: C1-T02, C1-T03, C1-T04, C2-T02, C4-T01, C6-T01.
