---
ticket_id: MP-R7-C5-T02
feature_id: MP-R7
chunk_id: MP-R7-C5
bucket: 1-refactor
repo: its-everdred/claude-app-server (issue only; cross-repo)
wave: 1
title: File the aiur-claude turn/steer text-drop defect on the sibling repository
status: blocked
blocked_by: [DESIGN-R7 §2 decision 2 (file now vs leave for E7)]
supersedes_if_declined: MP-E7-C4-T01
prior_units: []
prior_boundaries: [CLD (22)]
prior_features: [MP-E7]
prior_findings: [MP-R7 plan F7; phase-b-reconciliation "Live bugs" (not filed)]
size_owner: n/a (no code)
base_sha: 45a290e3
sibling_ref: "claude-app-server @ b1ea979 (origin/main == HEAD)"
researched: 2026-10-06
---

# MP-R7-C5-T02 — File the aiur-claude `turn/steer` defect

## Identity and outcome

- Bucket 1, MP-R7, chunk C5, ticket T02. Cross-repo: the action happens on
  the sibling repository; aiur gets no code change.
- **User value:** the defect becomes tracked where it can be fixed, before
  MP-E7 offers `steer` on headless Claude.
- **Deliverable:** one GitHub issue on `its-everdred/claude-app-server` with
  the reproduction below, linked from MP-E7-C4-T01.
- **Conditional:** runs only if Kevin answers DESIGN-R7 §2 decision 2 with
  "file now". If he answers "leave for E7", close this ticket as **superseded
  by MP-E7-C4-T01** (the sibling fix ticket), which then files and fixes in one
  step.
- **Non-goals:** no fix here; aiur does not call `turn/steer` today
  (`git grep turn/steer 45a290e3 -- src/lib` → no match).

## Dependencies and blockers

- **Blocked** on the owner answer above (it decides whether this ticket exists).
- Needs C5-T01's fixture only as a citation, not as a code dependency; may run
  before it.
- The Executor files issues (repo practice: agents author as `its-applekid`);
  this ticket is an Executor action, not an agent PR.

## Verified starting point (sibling @ `b1ea979`)

- `createTurn` builds every turn with an empty `steer_queue`
  (`src/server.ts:188-199`).
- `turnSteer` pushes `p.content` onto the **active** turn's queue and replies
  "queued: will be prepended to the next user message" (:496-510; push at :505).
- `turnStart` creates a **new** turn and then checks `turn.steer_queue` of
  that new turn, which is always empty (:464-470), so the active turn's queued
  text is never read. Steered text is dropped.
- `turnSteer` reads `params.content` only; Codex-shaped `input` arrays (which
  `turnStart` accepts at :455-461) are ignored, so a Codex-protocol client
  sending `{threadId, input, expectedTurnId}` is also dropped.
- `initialize` advertises `turns: ["start","steer","interrupt"]` (:312), so a
  client cannot detect the defect from capabilities.
- Even fixed, the design is turn-boundary (prepend to next turn), not
  mid-turn: `claude --print --output-format stream-json` is spawned per turn
  (`src/server.ts:5`, :690-725). That is MP-E7 RQ-E7-4's question, not this
  issue's.

## Chosen design

Issue text (to paste):

> **turn/steer drops the steered text.** `turnSteer` appends to the active
> turn's `steer_queue` (server.ts:505), but `turnStart` reads the queue of the
> turn it just created (server.ts:466-469), which `createTurn` initialises
> empty (server.ts:188-199). Repro: initialize → thread/start → turn/start
> (long prompt) → turn/steer {threadId, content:"X"} → wait for turn/completed
> → turn/start {input:"Y"} → the CLI receives only "Y". Also: turn/steer
> ignores Codex-style `input` arrays and `expectedTurnId`, and `initialize`
> advertises `steer`. Expected: either carry the active turn's queue into the
> next turn (thread-level queue) and accept `input`, or stop advertising
> `steer` and return MethodNotFound. Found by aiur MP-R7 research at b1ea979.

Labels: `bug`. No assignee chosen here (owner's call).

## Implementation steps

1. After DESIGN-R7 §2.2 = "file now", the Executor runs
   `gh issue create -R its-everdred/claude-app-server -t "turn/steer drops the steered text" -F <body file>`
   (body file avoids the inline `-m` hang noted in local operating notes).
2. Record the issue URL in MP-E7-C4-T01 and in the harness-adapter contract
   §3 note (coordinator edit).

## Non-happy paths

- Issue already exists (search first: `gh issue list -R its-everdred/claude-app-server -S steer`):
  link it instead of filing a duplicate.
- Repo moved/renamed: resolve the canonical repo from
  `git -C <sibling> remote get-url origin` before filing.

## Compatibility and rollout

n/a — no code, config or release.

## Verification

- The issue URL resolves and its body cites `b1ea979` line numbers.
- Re-read the three cited lines at the sibling's then-current `main`; if they
  moved, update the citations before filing.
- No automated test (no code change).

## Completion and handoff

- [ ] Owner answer recorded in DESIGN-R7.
- [ ] Issue filed (or ticket closed as superseded by MP-E7-C4-T01).
- [ ] URL linked from MP-E7-C4-T01.
- Docs: none.
