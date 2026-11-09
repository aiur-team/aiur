---
ticket_id: MP-E2-C1-T01
feature_id: MP-E2
chunk_id: MP-E2-C1
bucket: 2-platform
title: Persist v2 Command attributes in a request_attributed event
status: ready
blocked_by: [MP-R1-C11-T03]
prior_units: [U6, U8]
prior_boundaries: [DEC #27]
prior_features: [MP-R1 (identity contract, session_ref)]
prior_findings: [baseline § E2, MP-E2 plan §1.1, R-Q4 (answered here)]
size_owner: "n/a (current edited code <=500; all additions stay <=500; ledger c96025161f1688888de4159d8c31fb117a989b6a)"
base_sha: 4fbe109541ba1e279d3eb315d8455c4d139c92ba
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
- DESIGN-E2 header explicitly permits backend-only C1 to proceed. This admission uses that existing exception; it does not approve any visible presentation or native-capture default.
- Predecessors: none in MP-E2. Cross-feature: MP-R1 identity contract for the
  `session_ref` string (the pinned identity contract, §1.5 Worker and session); if MP-R1 has not
  landed, store `session_ref: nil`.
- Contract: [command-request-and-resolution.md](https://github.com/aiur-team/aiur/blob/de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0/docs/research/aiur-mobile-and-platform/contracts/command-request-and-resolution.md) §2, §3, §11.
- May run concurrently with C1-T02 (different files) and C3-T01.

## Verified starting point (post-refactor code scope)

- `src/lib/aiur/decision.ex:152-192` keeps schema version 1 and the ticket-bearing struct. The proposed v2 fields remain new work.
- `src/lib/aiur/decision_event.ex:22-53` owns event type registration; `new/5` remains the public constructor. Normalization has moved to `src/lib/aiur/decision_event/codec.ex:13-195`; unknown types still decode through `src/lib/aiur/decision_event/unrecognized.ex`.
- `src/lib/aiur/decision_projection.ex:43-80` validates requested snapshots; `:160` ignores Unrecognized records. Lifecycle transitions now delegate to `src/lib/aiur/decision_projection/reducers.ex`, with transport transitions in `delivery_reducers.ex`.
- `src/lib/aiur/decision_store.ex:70-82` exposes request/attention calls. `src/lib/aiur/decision_store/requests.ex:159-177` owns request handling. `src/lib/aiur/decision_store/persistence.ex:30-68` appends requested, projects it and repairs/notifies the projection; append helpers are in that same module.
- The old monolithic decision_store_test.exs is gone. Existing request/persistence tests are split under `src/test/aiur/decision_store/`; add new focused cases there rather than recreating the old file.
- Event normalization must extend Codec, projection must extend Reducers, and persistence must extend Persistence/Requests. Do not add those implementations back to the DecisionStore facade.

Refreshed against 4fbe109541ba1e279d3eb315d8455c4d139c92ba on 2026-10-25 (MP-R1-C11-T03). Scope: the named code paths above and implementation placement. Contract references retain their explicit research version; proposed files are new implementation work. Code citations were re-read at this SHA; contract links explicitly retain their pinned research version.

## Chosen design

- **Why an event and not snapshot fields:** an older binary recomputes the `requested`
  content hash from the fields it knows (`src/lib/aiur/decision_projection.ex:48-80`); extra fields
  would mismatch and latch the store read-only (`src/lib/aiur/decision_store/projection_recovery.ex`). A new event type
  is retained and skipped by older binaries (`src/lib/aiur/decision_event.ex:167-179`). The `requested`
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
5. `decision_event.ex` registers types; `decision_event/codec.ex` normalizes/encodes them. Append `Aiur.Commands.EventData.fact_types()` to `@types`; one
   clause `defp normalize_data(type, raw, _, _, _) when type in @command_fact_types, do:
   Aiur.Commands.EventData.normalize(type, raw)`; JSON encode via the same module.
6. `decision_projection/reducers.ex`: one `transition/2` clause delegating to
   `Aiur.Commands.Projection.apply/2` for `@command_fact_types`.
7. `decision_store/persistence.ex`: in `persist_and_notify/3` take the attributes from the request opts
   (threaded as `{decision, attrs}`), append the second event when attrs are non-empty.
   `request/4` and `project_attention/4` pass `opts[:requester|:origin|:native|:questions]`
   through unchanged. Add `lifecycle_version(:request_attributed, decision, _attrs), do: decision.version`
   before the fallback: a fresh request has no active answer from which to derive a version.
8. `decision_validation.ex`: reserved-identifier check in `normalize_ticket/1` path.
9. `decision_expiry.ex`: `expired_candidate?/4` returns false when
   `Requester.executor?(decision)`.
10. `decision_store/requests.ex` `lifecycle_slug/1` gains `request_attributed -> "request-attributed"` (C1-T03 owns the
    topic helper; this ticket adds only the slug).

## Non-happy paths

- Second append is known to have failed without a write (for example id reservation fails): Command accepted with defaults;
  log + one alert `decision.attributes.append_failed` (no content). A native Command
  without attributes cannot be replied in-band; delivery falls back to a message (§7.1).
- Replay of `request_attributed` before its `requested` (corrupt order): `fetch_current`
  returns `:decision_not_found` → existing corruption path (fail closed), unchanged.
- Rollback to a pre-ticket binary: events skipped; Commands show as v1. An Executor
  Command shows ticket `executor` and may expire after 300 s (release note).
- Ambiguous append and projection failure retain U6's existing typed recovery behavior: use `DecisionStore.Persistence` append/reconciliation and journal_failure_state rather than treating every error as a known non-write. Preserve accepted event identity and visible held-write/stale state.
- Concurrency: the GenServer serializes both appends; no interleaving.

## Compatibility and rollout

- No config. No migration: existing logs have no new events and project with defaults.
- Wire: additive event type; `requested` unchanged. Rollback safe (contract §11).
- Feature gate: none needed — no producer sets attributes until C4/C6.

RC-23 at 4fbe109541ba1e279d3eb315d8455c4d139c92ba: existing edit candidates were counted in the refresh admissions inventory. Keep every existing/new file <=500 lines; route new logic to the named small owner modules and new focused test files. Recheck actual scope at admission.

## Verification

Commands (TKD-19):

```bash
env -u GITHUB_TOKEN -u GH_TOKEN mise exec -- env -C src mix test --max-cases 4 \
  test/aiur/commands/event_data_test.exs test/aiur/commands/projection_test.exs \
  test/aiur/commands/request_attributes_test.exs test/aiur/decision_projection_test.exs \
  test/aiur/decision_expiry_test.exs test/aiur/decision_validation_test.exs
env -C src mix compile --warnings-as-errors && env -C src mix format --check-formatted && env -C src mix lint
```

| Test (PROPOSED name) | Expected | Fails without |
| --- | --- | --- |
| `commands/request_attributes_test` "request with requester opts appends request_attributed after requested" | log has 2 lines in order; the attributed event uses the requested decision version; `get/1` returns `requester.kind == :executor` | step 7 append |
| `commands/request_attributes_test` "requested snapshot hash is identical with and without attributes" | two events are appended and the first requested snapshot has the same `content_hash` for the same payload | step 7 append |
| `decision_projection_test` "request_attributed envelope decodes as Unrecognized when the type is unknown" | build the JSON with `to_json_safe`, rename nothing, call `Unrecognized.decode(raw, "request_attributed")` → an Unrecognized record retaining that type and event identity (existing forward-compatibility characterization) | future-regression guard only; not coverage for this change |
| `commands/request_attributes_test` "store restarts and replays request_attributed" | after restart fields equal | step 6 projection clause |
| `commands/request_attributes_test` "attribute append failure keeps the Command" | inject `event_id_reserver` failing on 2nd call; reply `{:ok, _}`, `requester` defaults to worker | step 7 failure branch |
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
