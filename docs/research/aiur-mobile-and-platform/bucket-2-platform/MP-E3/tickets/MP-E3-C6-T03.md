---
ticket_id: MP-E3-C6-T03
feature_id: MP-E3
chunk_id: MP-E3-C6
bucket: 2-platform
title: "Executor blockers and background-agents panels, with browser tests"
status: blocked
blocked_by: [DESIGN-E3, DESIGN-E2, MP-E3-C6-T01, MP-E3-C4-T02, MP-E3-C4-T03, MP-E4-C6-T02]
prior_units: [U8]
prior_boundaries: [WEB, EXE, DEC]
prior_features: [MP-E2 (Command cards)]
prior_findings: [plan acceptance 6; DESIGN-E3 decisions 7 (blockers scope)]
size_owner: "U8 WEB owner"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C6-T03 — Blockers and background-agents panels

## Identity and outcome

- Bucket 2 · MP-E3 · C6 · T03.
- **User value:** what the Executor waits on the operator for, answerable in
  place, and what it has running in the background.
- **Deliverable:** `AiurWeb.Executor.BlockersPanel` (items from
  `Executor.Blockers.snapshot/0`; Command items rendered with MP-E4-C6-T02's
  inline card, which delegates to the existing answer path) and
  `AiurWeb.Executor.BackgroundAgentsPanel` (rows or "Not available for this
  harness"); browser tests for both.
- **Non-goals:** new answer logic; subagent transcripts.

## Dependencies and blockers

- DESIGN-E3 (panels), DESIGN-E2 (Command card). MP-E3-C6-T01, MP-E3-C4-T02/T03,
  MP-E4-C6-T02 (inline card component).

## Verified starting point

- Command answer path: `DecisionEvents.handle("answer-decision", …)`
  (`src/lib/aiur_web/operator_control_center/decision_events.ex:30-32`) used by
  `DecisionAction` (`components/operator_control_center/decision_action.ex:59`).
- Projections: MP-E3-C4-T02 (`{:unsupported, reason}` vs `{:ok, rows}`),
  MP-E3-C4-T03 (per-source availability).

## Chosen design

- Blockers: one section per source; a source `{:unavailable, reason}` renders
  "unavailable" with the reason; `[]` with all sources ok renders the DESIGN-E3
  empty copy. Command items use the inline card; asks link to the CLI hint
  (`aiur ask --done <id>`) until MP-E2-C6-T03 turns them into Commands.
- Background agents: `{:unsupported, reason}` → "Not available for this
  harness" + reason; `{:ok, []}` → "No background agents"; rows show type, state,
  age, last message (≤ 500 chars, escaped).

## Implementation steps

1. Two components; 2. wire into `ExecutorLive`; 3. browser spec additions.

## Non-happy paths

- Command answered elsewhere → card resolves live (MP-E4-C6-T02 behaviour).
- Read-only dashboard → cards without answer controls.

## Compatibility and rollout

- UI only. Rollback: revert.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/executor/panels_test.exs
env -C src/browser node scripts/run-browser-tests.mjs tests/executor-view.browser.spec.mjs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "unsupported background agents render 'Not available', never 0" | text; no "0" | unsupported branch (plan acceptance 6) |
| "unavailable blockers source renders unavailable, not empty" | text | per-source branch |
| "Executor Command card answers through DecisionEvents" (spy) | called once | card reuse |
| browser "answer an Executor Command from the panel at 390 px" | resolved state shown | end to end |

## Completion and handoff

- Docs: `guide/gui.md` "Executor" section lists the panels (same PR as T01 or here).
