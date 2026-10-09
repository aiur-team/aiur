---
title: MP5 Fixer ticket filing and dispatch - Plan
type: feat
date: 2026-10-09
topic: merge-policy
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/merge-policy/brainstorm.md
base_main_sha: fd158cef8
---

# MP5 Fixer ticket filing and dispatch - Plan

## Goal Capsule

- **Objective:** with `on_red: dispatch_fixer`, a real main failure files one
  P1 fixer ticket and an agent starts on it ahead of all other work. The same
  failure never files twice.
- **Product authority:** [brainstorm.md](brainstorm.md) (R12, R13; F2, F4;
  AE5; Key Decisions "Daemon-filed fixer tickets are authorized by config",
  "At once means front of queue plus one reserved slot").
- **Open blockers:** MP4 (main-watch events).
- **Product Contract preservation:** unchanged.

---

## Problem Frame

The daemon has no issue-creation code. A ticket the daemon labels dispatches
only when an allowed user triaged it before
(`src/lib/aiur/github/dispatch_authorization.ex`, `prior_triage`), so a
daemon-filed ticket would sit forever. Dispatch sorts by downstream rank,
then priority (`src/lib/aiur/orchestrator/dispatch_policy.ex`), so a
`priority:1` ticket can still wait behind a full slot set.

## Requirements

- R12, R13 from the brainstorm.
- MP5-R1. The ticket body has: failing tests with classification, run URLs,
  red SHA, last green SHA, suspect PRs (early merges marked), the local
  command to reproduce (`mix test <file>:<line>` when known), and the rule
  "this PR waits for full CI".
- MP5-R2. Dedupe: an open issue with `fixer_label` and the same signature
  marker gets a comment with the new run; a different signature while one
  fixer is open files a second ticket only when the failing tests do not
  overlap.
- MP5-R3. On `.resolved`, comment on the open fixer ticket ("main is green at
  <sha>") and raise attention when no PR is open for it; never close it.
- MP5-R4. Under PAT auth (daemon and agents share a login), file with
  `needs-triage` instead of `agent:todo` and raise an alert.

## Key Technical Decisions

- **Filed with the daemon credential through `Aiur.GitHub.WriteThrough`**,
  labels `agent:todo`, `priority:1`, `complexity:1`, `fixer_label`. Marker
  `<!-- aiur:main-watch signature=<hash> sha=<sha> -->` in the body.
- **Authorization rule** in `DispatchAuthorization`: allow when the issue
  author is the App account, the body has a well-formed main-watch marker,
  the issue has `fixer_label`, and the live config has `on_red:
  dispatch_fixer`. Reason string `main_watch_fixer`. This is narrower than
  `prior_triage` and only applies in App mode.
- **Front of queue**: `dispatch_policy.ex` sorts tickets with `fixer_label`
  before all others.
- **Reserved slot**: `slots.ex` allows one running fixer ticket above the
  agent cap; the host load gate still applies.
- **Dispatch watchdog**: if the fixer ticket is not running 5 min after
  filing, emit attention `system.main.fixer.stalled` naming the reason
  (authorization, load gate, budget hold).
- **Known-flake-only failures file nothing** (MP4 already emits `flaked`).

## Implementation Units

### U1. Issue filer with dedupe

**Goal:** turn a `system.main.ci.failed` event into one ticket or one comment.
**Requirements:** R12, MP5-R1, MP5-R2, MP5-R4.
**Files:** `src/lib/aiur/main_watch/fixer.ex` (new), `src/lib/aiur/github/issues.ex`
(create-issue call), `src/test/aiur/main_watch/fixer_test.exs` (new).
**Test scenarios:**
- Covers F2. First failure: one issue with the four labels and the marker.
- Covers AE5. Same signature again: comment on the existing issue, no new
  issue.
- Different signature, overlapping failing test: comment, no new issue.
- Different signature, disjoint tests: second issue.
- PAT mode: `needs-triage` label, alert, no `agent:todo`.
- Issue create returns 422/5xx: alert with the error; retry on the next event.

### U2. Dispatch authorization rule

**Goal:** the fixer ticket is dispatchable without a human relabel.
**Requirements:** R12.
**Files:** `src/lib/aiur/github/dispatch_authorization.ex`,
`src/test/aiur/github/dispatch_authorization_test.exs`.
**Test scenarios:**
- App-authored, marker, label, `dispatch_fixer`: authorized
  (`main_watch_fixer`).
- Same with `on_red: alert`: denied.
- Agent-authored (bot_account) issue with a copied marker: denied.
- Marker present, `fixer_label` removed: denied.

### U3. Priority and reserved slot

**Goal:** the fixer starts at once.
**Requirements:** R12.
**Files:** `src/lib/aiur/orchestrator/dispatch_policy.ex`,
`src/lib/aiur/orchestrator/slots.ex`, tests
`src/test/aiur/orchestrator/dispatch_policy_test.exs`,
`src/test/aiur/orchestrator/slots_test.exs`.
**Test scenarios:**
- Full slots, fixer ready: fixer dispatches (cap + 1).
- Two fixer tickets ready, full slots: only one extra slot used.
- Host load gate closed: fixer waits; stalled alert after 5 min.
- Fixer sorts before a `priority:1` ticket with higher downstream rank.

### U4. Recovery handling

**Goal:** close the loop without racing an agent.
**Requirements:** MP5-R3.
**Files:** `src/lib/aiur/main_watch/fixer.ex`, test.
**Test scenarios:**
- Covers F4. `.resolved` with fixer open and PR open: comment only.
- `.resolved` with fixer open and no PR: comment plus attention.

## Scope Boundaries

- No automatic revert of the suspect PR (possible later; open question for
  the Executor's playbook, not this ticket).

## Risks

- The reserved slot can push a loaded host further. The load gate stays
  authoritative.

## Verification Contract

- Unit tests above; a staged event in a test daemon files, dedupes and
  dispatches.

## Definition of Done

- Merged and rebuilt; on the next real red main, a fixer ticket is filed and
  running within 5 minutes with no Executor action.
