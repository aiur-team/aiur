---
ticket_id: MP-E2-C4-T01
feature_id: MP-E2
chunk_id: MP-E2-C4
bucket: 2-platform
title: NativeCapture core — classify, map and record native questions
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C4-T00, MP-E2-C1-T01, MP-E2-C1-T02]
prior_units: [U6, U4]
prior_boundaries: [DEC #27, RUN #18, CDX #21]
prior_features: [MP-R7 (harness-adapter §6, MP-R7-C2-T2 reserved callbacks)]
prior_findings: [D10, R-Q1, plan §1.4, contract §3 (secrets), §10]
size_owner: "n/a — new module (≤ 200 lines)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C4-T01 — NativeCapture core: classify, map and record native questions

## Identity and outcome

- Bucket 2, MP-E2, chunk C4 (native capture, Codex first).
- **User value:** an agent's own "ask the user" question becomes a Command you can answer,
  instead of being answered within milliseconds by "This is a non-interactive session"
  and lost (plan §1.4).
- **Deliverable:** PROPOSED `Aiur.Commands.NativeCapture` (harness-neutral):
  - `classify(normalized) :: :approval | :secret | :question`
  - `to_request(normalized, ctx) :: {:ok, payload, opts}` for `DecisionStore.request/4`
  - `capture(normalized, ctx) :: {:command, Decision.t()} | {:release, text} | {:policy, :approval}`
  - `release_text(decision_id)`, `secret_release_text/0`.
- **Non-goals:** holding the JSON-RPC request (C4-T02); delivering (C4-T03); Claude
  (C5). No harness module is edited here.

## Dependencies and blockers

- **DESIGN-E2**; **C4-T00** (the recorded request shape is the test fixture and may change
  field names below); C1-T01 (attributes), C1-T02 (`normalize_questions/1`).
- MP-R7: if MP-R7-C2-T2 has landed, the input is the adapter's normalized
  `{:native_question, …}` (harness-adapter §6 item 3); before R7, C4-T02 builds the same
  map from the Codex params. Either way this module sees only the normalized map.
- May run concurrently with C2, C3, C6.

## Verified starting point (`45a290e3`)

- Approval heuristic to reuse, not copy: `Aiur.Codex.UserInputAnswers.approval_answers/1`
  (`codex/user_input_answers.ex:8-28`; label rule `:70-92`: "Approve this Session",
  "Approve Once", or any label starting "approve"/"allow").
- Creation path to mirror: `agent_runner/tool_executor.ex:568-660` (`request_decision/5`
  builds trusted `ticket`, `source` via `trusted_source/1` `:844-850`, `provenance`).
- Alerts: `Aiur.Alerts.emit_custom/3` (example `orchestrator/runtime_watchdog.ex:332-341`).
- Command creation API: `DecisionStore.request/4` `decision_store.ex:154-160`.

## Chosen design

Normalized input (harness-adapter §6 item 3 / contract §10 item 3):

```elixir
%{harness: :codex | :claude, native_ref: String.t(), call_id: String.t() | nil,
  turn_id: String.t() | nil, blocking: boolean(),
  questions: [%{question_id, header, question, options: [%{label, description}],
               multi_select, allow_other, secret}]}
```

- `classify/1`: `:approval` when **every** question's options satisfy the existing
  approval rule (delegate to `UserInputAnswers.approval_answers/1` on a re-shaped map, so
  D10 stays one heuristic); `:secret` when any question has `secret: true`; else
  `:question`. Classification is public for tests (contract §10 item 2).
- `to_request/2`: `source_id = "native:" <> native_ref` (stable ⇒ same `decision_id` on a
  retry of the same request); `question` = first question text (or "N questions: h1, h2…"
  when > 1); `options` = first question's options with ids `o1..oN`;
  `context.short_summary` = first `header`; authority and reversibility are left unset so
  the validator's defaults apply (`supervisor_allowed`, `reversible`,
  `decision_validation.ex:56-58`) and routing (D9) lets the Executor answer simple ones
  first — the agent asked "the user", and in aiur the Executor is the first responder for
  delegable questions; `blocking` from the request (`isBlocking`, default true);
  `kind: "native_question"`.
  Opts: `requester: %{kind: :worker, ticket, session_ref, harness}`,
  `origin: :native_question`, `native: %{…, hold: :in_band}` (C4-T02 may downgrade),
  `questions:` from `RequestContent.normalize_questions/1`.
- `capture/2`: `:approval` → `{:policy, :approval}` (caller keeps today's behaviour);
  `:secret` → emit alert `ticket.<id>.agent.native-secret-question`
  (`needs_attention: true`, no text) and `{:release, secret_release_text()}`;
  `:question` → `DecisionStore.request/4` → `{:command, decision}`; on store error →
  `{:release, UserInputAnswers.non_interactive_answer()}` (fail to today's behaviour) and
  a warning log.
- Texts: `release_text(id)` = "Your question is recorded as Command #{id}. Stop and end
  your turn; the answer will arrive as a message."; `secret_release_text/0` = "aiur cannot
  collect secrets through Commands."

## Implementation steps

1. PROPOSED `src/lib/aiur/commands/native_capture.ex` (≈170 lines).
2. PROPOSED fixtures `src/test/fixtures/codex/request_user_input/{question,approval,secret,multi}.json`
   copied from C4-T00's `fixtures/` (real frames, not hand-written).
3. PROPOSED `src/test/aiur/commands/native_capture_test.exs`.

## Non-happy paths

- Store read-only / unavailable → release with today's text; the agent behaves as today.
- Duplicate capture of the same request (retry) → same `decision_id` → `:duplicate` →
  `{:command, existing}`.
- Malformed question (no id) → `{:release, non_interactive_answer}` (today the malformed
  path returns `:input_required`, `codex/approvals.ex:278-280`; keep that mapping in
  C4-T02 for the truly malformed case).
- Privacy: secret questions never reach the store; the alert carries no question text.

## Compatibility and rollout

- Inert until C4-T02 calls it behind `decisions.native_capture.codex` (default false).

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur/commands/native_capture_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "approval fixture classifies as approval" | `:approval` | delegation to the D10 heuristic |
| "question fixture creates one Command with origin native_question" | one `requested` + `request_attributed`; `native.hold == :in_band`; `question_ids` match fixture ids | `to_request/2` + attrs |
| "same native_ref twice yields the same decision" | second `{:command, d}` with equal `decision_id`, store `:duplicate` | `source_id` derivation |
| "secret fixture is not persisted" | store dir (temp) has no line containing the fixture's question text; alert emitted with no text | `:secret` branch |
| "multi-question fixture fills v1 question and options" | `question` lists headers; options = first question's | v1 fill |
| "store unavailable releases with today's text" | `{:release, "This is a non-interactive session. …"}` | error branch |

Mutation check per row (worktree).

## Completion and handoff

- [ ] Module + real fixtures; no harness edits.
- Docs: none yet (C8-T01 documents native questions).
- Dependents: C4-T02, C4-T03, C4-T04, C5-T02.
