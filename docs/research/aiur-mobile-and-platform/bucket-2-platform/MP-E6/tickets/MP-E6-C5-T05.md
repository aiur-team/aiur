---
ticket_id: MP-E6-C5-T05
feature_id: MP-E6
chunk_id: MP-E6-C5
bucket: 2-platform
title: propose_command_answer — Command-answer drafts with version capture, stale detection and E2 delivery
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend; confirm UI is C7-T03)", MP-E6-C5-T02, MP-E6-C4-T05, MP-E2]
prior_units: []
prior_boundaries: [VOX, DEC]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C5-T05 — Command-answer drafts

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C5.
- **User value:** the operator talks a blocker through and ends with a precise answer the
  assistant drafted ("pick option B, but keep the old column for a week"), confirmed with one
  tap, recorded through the same Command path as every other answer.
- **Deliverable:** tool `propose_command_answer(decision_id, option_id | custom_text)` →
  `command_answer` draft carrying `base_version`; on confirm (C5-T03 flow) →
  `DecisionStore.answer(decision_id, %{"option_id" | "custom_response", "expected_version" =>
  base_version, "idempotency_key" => draft_id}, actor: operator)`; E2 conflicts mapped to
  draft `stale` with E2's reason.

## Dependencies and blockers

- **Predecessors:** C5-T02; C4-T05 (resolved events); MP-E2 (answer contract, conflict
  summary NEW in command contract §5 rule 1).

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Answer API | `DecisionStore.answer/5` (`decision_store.ex:190`); payload keys as built in `decision_commands.ex:85-107` |
| Validation | option must exist (`{:answer_invalid, {:option_id, :unknown}}`), text ≤ 4,000 (`decision_answer.ex:15,251`) |
| Conflicts | `{:conflict, {:stale_version, _, current}}`, `{:already_decided, _}`, `{:idempotency_conflict, _}`, `:resolved` (`decision_commands.ex:347-357`) |
| Actor | dashboard answers use `%{kind: :operator, id: …}` (`decision_commands.ex:81-83`) |

## Chosen design

- At propose: read the Command (port); refuse unknown option ids and non-answerable statuses
  with a tool error text; store `base_version`.
- Stale triggers: resolved/answered event (C4-T05), version change on re-read at confirm.
- Conflict mapping: `stale_version` / `already_decided` / `resolved` → `stale` with E2's
  human text; `idempotency_conflict` → `failed` ("already recorded differently") — never
  retried automatically.
- Actor: `%{kind: :operator, id: <dashboard user or device_id>, via: :voice_assistant}` if
  E2 accepts a `via` field (command contract; otherwise omit — not a blocker).

## Implementation steps

1. Tool handler; 2. confirm path to `DecisionStore.answer/5` (injected server); 3. conflict
   mapping; 4. tests with a temp-dir `DecisionStore`.

## Non-happy paths

Answered elsewhere between propose and confirm → `stale`; text stays visible to copy.

## Compatibility and rollout

Uses the existing answer API unchanged. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "confirm records the answer with idempotency_key = draft_id and the base version" | store has the answer; key matches |
| "a Command resolved meanwhile makes the draft stale and records nothing" | — |
| "an unknown option is refused at propose" | tool error, no draft |
| "double confirm records once" | `:duplicate` from the store treated as success |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/command_answer_draft_test.exs
make -C src fmt-check lint
```

Store on a temp dir (`:decision_state_dir`). Run in an implementation worktree with
`GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check `~/.aiur/github-budget/agent-token` before and
after.

**Mutation check.** Send the current version instead of `base_version`: the "resolved
meanwhile" variant with a version bump records an answer and the test fails.

## Completion and handoff

- [ ] Command-answer drafts end to end (backend).
- **Dependents:** C7-T03, MP-N6-C4-T03 ("Converse path … confirm-to-answer").
