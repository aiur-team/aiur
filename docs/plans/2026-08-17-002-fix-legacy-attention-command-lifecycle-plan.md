---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
date: 2026-08-17
---

# Legacy-Attention Command Lifecycle — Plan

## Goal Capsule

**Objective.** A Command whose ticket is closed, or whose originating agent no longer exists, can be retired with a recorded reason and without fabricating an answer. Duplicate Commands for one question collapse at creation, not only at answer time. Legacy-attention conversions are a distinct, retirable kind.

**Product authority.** Issue #2099 (its-everdred), 2026-08-17.

**Open blockers.** None.

## Problem Frame

Nine Commands are open on the dogfood daemon, all `kind: legacy_attention`, all `authority: human_required`, eight `blocking: true`. Four concern closed tickets (`#2071` ×3, `#1674`). Three of the four `#2071` Commands were created by the same agent within ~48 ms with paraphrased questions.

Three defects:

1. **No moot disposition.** `executor-answer` is refused by the store floor (`authority: :human_required`), `executor-escalate` only notifies, and `ask --done` belongs to the operator-request subsystem. A Command about a closed ticket is permanently stuck. There is no way to record "this question is void" without inventing an answer.
2. **Duplicates are created, not just cleared.** #2072 clears duplicates on answer; the same agent can still file several phrasings of one question as separate Commands.
3. **Legacy conversion defaults.** Converting an attention record inherits `human_required` + `irreversible` from `DecisionValidation` defaults; the delegation floor then refuses every one of them, so the delegable-answer path is dead for legacy records, and each one that concerns a closed ticket blocks forever.

## Requirements (from issue #2099 acceptance)

- **R1** A Command whose ticket is closed, or whose originating agent no longer exists, can be retired with a recorded reason and without fabricating an answer.
- **R2** Retiring it is attributable to whoever retired it, and is distinguishable in the durable record from a real answer. It must not be solved by the Executor answering through an operator-attributed API.
- **R3** Two Commands from one agent, one ticket, inside a short window, with substantially the same question, produce one Command. Assert the count.
- **R4** After the fix, `aiur commands --blocking` reports only Commands a human genuinely still needs to decide (9 → 5 on the daemon after the four closed-ticket Commands are mooted).

## Scope Boundaries

**In scope.** The moot disposition (status + event + store API + CLI + dashboard read), creation-time dedup, and tests proving the acceptance criteria. Docs for the new CLI surface.

**Out of scope.** An automatic tracker-state sweep that moots closed-ticket Commands on its own: determining "ticket closed" requires tracker queries the DecisionStore does not perform, and R1/R4 are satisfied by a retirable disposition the operator applies. A future sweep can reuse the same `:moot` event.

### Deferred to Follow-Up Work

- Automatic sweeping of closed-ticket Commands via tracker state (reuses the moot event).
- Changing legacy-attention `authority` away from `:human_required` (a semantic decision about whether a supervising agent may auto-answer attentions; R3's dedup and the moot disposition remove the pile-up and the permanent-block harms).

## Key Technical Decisions

### KTD-1 — New `:moot` decision status + `:decision_mooted` event

A dedicated status and event, not a reuse of `:expired` and not a dismiss.

- `dismiss` refuses agent-filed blocking Commands (`unresolvable_block?/1`) because it would turn a visible block invisible; moot is the *opposite* — the question itself is void, so the block is moot too and may be retired.
- `:expired` is system-driven (`agent_not_running`) with a system actor and no reason text; moot is an attributed, reason-recorded disposition.
- Distinguishable from a real answer in the durable record: `answer` stays `nil`, `decision_status` is `:moot`, and the event carries `{reason_class, detail, actor}` — never a `DecisionAnswer`.

Rejected: having the Executor answer through an operator-attributed path (launders attribution, R2 forbids it); a silent dismiss (records no reason).

### KTD-2 — Moot may retire any open/deferred Command regardless of blocking

`blocking` and `authority` describe a *live* question. A closed ticket or a gone agent voids the question, so neither the blocking refusal nor the `human_required` floor applies. This is exactly how the four `#2071`/`#1674` Commands (blocking + human_required) become clearable.

### KTD-3 — Creation-time dedup on (ticket, agent, short window, similar question)

In the request acceptance path (and the legacy-attention projection path), before accepting a fresh Command, look for an existing `:open`/`:deferred` Command from the same `source.agent_id` on the same `ticket.identifier` whose question is substantially similar, created within a short window (module constant, 60 s). If found, return `status: :duplicate` referencing the existing Command and append nothing.

"Substantially similar" = exact-after-normalization equality (reusing `normalized_question/1`) OR token-overlap similarity ≥ threshold (Sørensen–Dice on token sets, threshold 0.5). The three `#2071` paraphrases score 0.59–0.79, so 0.5 collapses them while leaving genuinely different questions alone.

Rejected: exact-normalization-only (the three `#2071` phrasings are paraphrases and would survive); embedding-based similarity (heavyweight, no precedent in the tree).

### KTD-4 — Legacy conversions are a distinct, retirable kind

`project_attention` already writes `kind: "legacy_attention"` and `blocking: false` (#2072). With KTD-1/KTD-2, these records are retirable via moot. No change to their `authority`/`reversibility` defaults; that is deferred.

## High-Level Technical Design

State machine for the Decision lifecycle after this change:

```text
requested → open ──┬─ answer ──→ decided
                   ├─ defer ───→ deferred ── answer ──→ decided
                   ├─ dismiss ─→ dismissed     (refused for agent-filed blocking)
                   ├─ expire ──→ expired       (system, agent_not_running)
                   └─ moot ────→ moot          (attributed, reason recorded; may retire blocking)
```

The `:moot` status joins the retained index lifecycle sets and query_plan's `@historic_statuses`, so mooted Commands leave `commands --blocking` (`lifecycle: open` + `blocking: true`) and the `open`/`blocking`/`awaiting` counts, while staying visible under `--filter resolved` and in the audit history.

## Implementation Units

### U1. Moot disposition in the store

**Goal.** Add `DecisionStore.moot/4` that durably records an attributed, reason-carrying `:decision_mooted` event and transitions an `:open`/`:deferred` Command to `:moot`, with `answer` untouched.

**Requirements.** R1, R2.

**Dependencies.** None.

**Files.**
- `src/lib/aiur/decision.ex` — add `:moot` to the `decision_status` type and doc list.
- `src/lib/aiur/decision_event.ex` — add `:decision_mooted` to `@types`/type union; `normalize_data(:decision_mooted, …)` (required `reason_class` ≤200, optional `detail` ≤2000, any-actor); `data_to_json_safe(:decision_mooted, …)`.
- `src/lib/aiur/decision_projection.ex` — transitions `:open`/`:deferred` → `:moot` (idempotent on `:moot`).
- `src/lib/aiur/decision_store.ex` — public `moot/4` + `handle_call({:moot, …})`; validation (status open/deferred, reason_class + actor present); persistence via `build_and_persist_event(:decision_mooted, …)`; `lifecycle_slug(:decision_mooted)` → `"mooted"`.
- `src/lib/aiur/decision_store/retained_index.ex` — add `:moot` to `@lifecycle_statuses`.
- `src/lib/aiur/decision_store/retained_snapshot.ex` — add `:moot` to `@lifecycle_statuses`.
- `src/lib/aiur/decision_store/retained_snapshot/query_plan.ex` — add `:moot` to `@lifecycle_statuses` and `@historic_statuses`.
- `src/lib/aiur/decision_history.ex` — map `decision_mooted` → `:mooted` event kind, actor + rationale from the event data.

**Approach.** Mirror the `expire` path exactly: public API → `handle_call` → fetch → validate → `build_and_persist_event`. Unlike `expire` (system actor only), `moot` accepts the caller's actor via `opts[:actor]` (operator or executor) and records a free-text reason alongside the bounded `reason_class`. Idempotent: a second `moot` on a `:moot` Command returns `status: :duplicate`.

**Patterns to follow.** `persist_expiration/4`, `persist_dismissal/3`, `handle_expire/4`, `normalize_data(:decision_expired, …)`.

**Test scenarios.** In `src/test/aiur/decision_store_test.exs`:
- Happy path: moot an open Command → status `:moot`, `answer` nil, audit history has `[requested, decision_mooted]` with the recorded actor and `reason_class`.
- Idempotence: second moot returns `status: :duplicate`.
- Refused when already answered (`:conflict`).
- Retiring a blocking legacy-attention Command (the #2099 shape) succeeds and leaves `blocked_ticket_ids`/`commands --blocking` empty for that ticket — Covers R4.
- Durability: restart the store, the `:moot` status and the event replay.
- Write-gated (`:store_unavailable` when `writable?: false`).
- Historic: `retained_query lifecycle: :historic` returns the mooted Command; `lifecycle: :open` does not.

### U2. `executor-moot` CLI

**Goal.** Add `aiur executor-moot <decision-id> --expected-version <n> --reason-class <class> [--reason <text>] [--executor-id <id>]` so an operator/Executor can retire a moot Command from the terminal.

**Requirements.** R1, R2.

**Dependencies.** U1.

**Files.**
- `src/lib/aiur/executor_command_cli.ex` — add `moot/2` (parse flags, call `DecisionStore.moot/4` with `actor: %{kind: :executor, id: executor_id}`, print/error helpers matching `answer`/`escalate`).
- `src/lib/aiur/agent_control_cli.ex` — add `executor_moot/1` guarded dispatch.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` — `cmd_executor_moot`, usage line, dispatch case entry.
- `website/docs-app/reference/cli.md` — document the command under the "Act on durable records" table.
- `src/test/aiur/executor_command_cli_test.exs` (or the existing executor CLI test file) — parse + store-call tests.

**Approach.** Match `cmd_executor_escalate` (decision ID positional, `--expected-version`/`--reason` flags, base64-encoded control values). Attribution stays the Executor running the CLI (`kind: :executor`); the event is not an answer and does not impersonate the operator, satisfying R2.

**Test scenarios.**
- `moot/2` forwards `decision_id`, `expected_version`, `reason_class`, `reason`, `executor_id` to the store and prints the success line.
- Missing/empty `--reason-class` → usage error (exit 64) without a store call.
- Store error (e.g. `{:not_open, :decided}`) → `command_error` with exit 1.
- Engine shell test for the new command parsing (if a shell test harness exists for `executor-escalate`).

### U3. Creation-time dedup

**Goal.** Collapse two Commands from one agent, one ticket, inside a short window, with substantially the same question into one Command at creation.

**Requirements.** R3.

**Dependencies.** None (independent of U1/U2; reuses `normalized_question/1` already in the store).

**Files.**
- `src/lib/aiur/decision_store.ex` — in the request acceptance path (`evaluate/3` → `evaluate_fresh`) and the legacy-attention projection path (`apply_attention_projection_for_source`), before accepting a fresh Command, run a `recent_similar_from_same_agent/2` check; return `{:duplicate, existing}` when it matches. Add the window constant, the tokenizer, and the Sørensen–Dice similarity helper (module-private).
- `src/test/aiur/decision_store_test.exs` — creation dedup tests.
- `src/test/aiur/decision_attention_test.exs` — legacy-attention dedup at conversion.

**Approach.** Match on: different `decision_id`; `decision_status in [:open, :deferred]`; same `ticket.identifier`; same non-empty `source.agent_id`; `created_at` within the window of the incoming Command; `substantially_same_question?/2`. Return the newest matching existing Command. Do not apply when `source.agent_id` is absent.

**Test scenarios.**
- Two `request` calls from the same agent/ticket within the window with normalized-equal questions → second returns `status: :duplicate`; `DecisionStore.list()` count is 1 — Covers R3 (assert the count).
- Two paraphrased questions (the three-`#2071` shape) from the same agent/ticket within the window → one Command (count 1).
- Same question from a different agent or different ticket → two Commands (no false collapse).
- Same question from the same agent but older than the window (created_at outside 60 s) → two Commands.
- After the window candidate is answered (`:decided`), a new similar Command is accepted (not matched against decided).
- Attention-path dedup: two `project_attention` calls with similar questions from the same agent → one Command.

### U4. Legacy-attention retirability + adjust supersede test

**Goal.** Prove legacy-attention Commands are retirable via moot (defect 3 via the distinct-kind option) and keep the #1844 answer-time supersede behavior covered now that creation dedup intercepts the same-agent case.

**Requirements.** R1, R2, R3, R4.

**Dependencies.** U1, U3.

**Files.**
- `src/test/aiur/decision_store_test.exs` — moot a legacy-attention Command; adjust the #1844 supersede test so its duplicate is created by a different agent (creation dedup would otherwise intercept it), preserving the answer-time-clear assertion.
- `src/test/aiur/decision_attention_test.exs` — a legacy attention about a "closed" ticket can be mooted via the store and no longer appears as blocking.

**Approach.** No production change beyond U1/U3; the distinct `kind: "legacy_attention"` already exists and moot is status-based, so any open Command (including a blocking, human_required, legacy-attention one) is retirable.

**Test scenarios.**
- Moot a `blocking: true`, `authority: "human_required"`, `kind: "legacy_attention"` Command (the exact daemon shape) → `:moot`, answer nil, `commands --blocking`/`blocked_ticket_ids` excludes it — Covers R4.
- #1844 supersede: a different-agent duplicate is still dismissed when the primary is answered, with the `superseded-by:` actor in the audit trail.

### U5. Docs

**Goal.** Update `website/docs-app/reference/cli.md` for `executor-moot` and the blocking-count semantics.

**Requirements.** R4 (CLI surface documented).

**Dependencies.** U2.

**Files.**
- `website/docs-app/reference/cli.md` — add `executor-moot` rows to the "Act on durable records" table; note that retiring a Command via moot removes it from `commands --blocking` and records a reason without answering it.

**Approach.** Match the existing `executor-escalate` row style. Do not pad.

**Test scenarios.** `Test expectation: none` — docs only.

## Verification Contract

- `mix compile --warnings-as-errors` from `src/`.
- `mix format` clean.
- `cd src && mise exec -- mix aiur.affected_tests` → run the printed scoped command with `--max-cases 4`; every test in it passes.
- The draft PR self-review confirms each PR-body claim is supported by the diff.

## Definition of Done

- `DecisionStore.moot/4` exists, is durable/idempotent/historic/write-gated, records an attributed `reason_class` + reason, and never sets `answer`.
- `aiur executor-moot` works end-to-end and is documented.
- Two same-agent, same-ticket, short-window, substantially-similar Commands create one Command (count asserted).
- A blocking `human_required` legacy-attention Command can be mooted and leaves the blocking surface.
- The four closed-ticket Commands on the daemon are clearable, leaving 5 in `commands --blocking`.
