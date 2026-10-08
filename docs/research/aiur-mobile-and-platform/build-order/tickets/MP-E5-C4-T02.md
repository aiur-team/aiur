---
ticket_id: MP-E5-C4-T02
feature_id: MP-E5
chunk_id: MP-E5-C4
bucket: 2-platform
title: Dictate a revised Command response on the revision form
status: blocked
blocked_by: [DESIGN-E5, E5-OQ3, DESIGN-E2, MP-E5-C4-T01]
prior_units: [U8]
prior_boundaries: [VOX, WEB, DEC]
prior_features: [ui-07]
prior_findings: []
size_owner: WEB (decision_revision_action.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C4-T02 — Dictated Command revisions

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C4.
- **User value:** the operator can revise an answered Command by voice with the same review
  rule as answering it.
- **Deliverable:** `<.voice_input>` on `revision[custom_response]` in
  `DecisionRevisionAction.decision_revision_action/1`, reusing exactly the C4-T01 controller
  flow (auto-select per E5-OQ3, field wait, 4,000 cap). Submission unchanged:
  `revise-decision`.
- **Scope decision for DESIGN-E5:** whether the "Reason for revision" field (`:123-126`,
  also `maxlength="4000" required`) also gets a mic. DESIGN-E5 §2 lists the revision form
  "same as Command response", which names only the response; this ticket attaches voice to
  the response field and adds the reason field **only** if DESIGN-E5 says so (one extra
  `<.voice_input>` bound by `data-voice-input-for="revision[reason]"`).
- **Non-goals:** follow-up form (`:144-150`), which is an Executor flow.

## Dependencies and blockers

- **Owner:** DESIGN-E5, E5-OQ3, DESIGN-E2.
- **Predecessors:** MP-E5-C4-T01 (controller flow).

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Form | `decision_revision_action.ex:80-86` `id="decision-revision-form-<id>"`, `phx-change="decision-revision-change"`, `phx-submit="revise-decision"` |
| Custom radio and field | `:107-113`, `:118-121` (`:if={@choice == "custom"}`, `maxlength="4000" required`) |
| Reason field | `:123-126` |
| Handlers | `DecisionEvents.handle("decision-revision-change" | "revise-decision", …)` → `RevisionCommands` (`decision_events.ex:55-60`) |

## Chosen design

Identical to C4-T01 with `data-voice-select-custom="revision[choice]"`,
`surface: "command_revision"` and `target: {kind: "command", decision_id,
expected_version}`.

The answer-form rule of C2-T01 (`decision_status in [:open, :deferred, :dismissed]`) is wrong
for revisions: the revision form is rendered exactly when the Command **has an answer**
(`decision_revision_action.ex:43`, `<section :if={@decision.answer}>`). So `VoiceTargets`
gets a `command_revision` surface whose rule is "`DecisionStore.get/2` returns a decision
with `answer != nil`, and `expected_version` (if given) equals `version`". Whether the store
then accepts the revision is decided by the existing revise path (`RevisionCommands.revise/4`,
`decision_events.ex:59-60`); a refusal there is shown with the existing error and the text is
kept.

## Implementation steps

1. Add `command_revision` to the contract's surface list (§3.2) and to `VoiceTargets`.
2. Form wiring as in C4-T01.
3. Docs: `concepts/commands.md` revision paragraph.

## Non-happy paths

Same table as C4-T01; plus "revision no longer allowed" (Command delivered and closed): the
existing `RevisionCommands` error is shown and the text kept.

## Compatibility and rollout

Additive; no payload change. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| LiveView "dictated revised response is submitted with revise-decision" | payload has `revision[choice]=custom` and the text |
| `voice_targets_test.exs` "a revision target needs an answered Command" | decision with `answer: nil` → `target_stale`; with an answer → `:ok`; moved `expected_version` → `target_stale` |
| browser "revision dictation auto-selects Custom response" | as C4-T01 |

```bash
env -C src mise exec -- mix test test/aiur_web/voice_targets_test.exs
env -C src/browser npm run test:units
make -C src fmt-check lint
```

Run Elixir tests in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and
hash-check `~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Make the `command_revision` surface reuse the answer-form status rule:
the "needs an answered Command" test fails for an answered (`:resolved`) Command with an
answer.

## Completion and handoff

- [ ] Revision form dictation; contract §3.2 surface list updated; docs in PR.
- **Dependents:** none beyond C6.
