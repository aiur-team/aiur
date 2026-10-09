---
title: BQ-G2 optimistic worker - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
date: 2026-10-09
epic: aiur-team/aiur#3755
area: G2 optimistic worker
code_baseline: origin/main 0e5b8d0de
---

# BQ-G2 optimistic worker - Plan

## Goal Capsule

- **Objective.** When the dispatcher starts a ticket whose blocker is not yet merged (G1 decided *when*), the worker starts correctly: on the blocker's latest pushed code, subscribed to the blocker's events before its first turn, and with standing instructions to pull every blocker push, keep its PR stacked and in draft, and rebase (not merge) when the blocker's history is rewritten.
- **Product authority.** Kevin, epic #3755 (verbatim intent in the brief): "if an agent does optimistically begin work, they should be auto-subscribed to when commits are pushed in their parent dependency (so that they can pull those in quickly and incorporate the new code)"; "this may need a skill change too".
- **Open blockers.** None inside G2. G2 is inert until G1 ships a trigger that lets dispatch pass an open blocker (the default `pr_merged` never dispatches optimistically).
- **Mode.** Brainstorm run unattended. Every question the skill would ask was decided here from the operator intent and the code; each decision carries its reason. Operator-only questions are at the end.

## Current state (verified on origin/main 0e5b8d0de)

- `aiur_declare_blocker` binds 9 blockee topics (`ticket.N.branch.push`, `.branch.force-push`, `.pr.opened`, `.pr.merged`, `.agent.decision.*`, `.agent.blocked`, `.agent.unblocked`, `.agent.attention.*`, `.issue.commented`) and 2 reverse topics, with reason `blocker:auto` (`src/lib/aiur/orchestrator/auto_subscriptions.ex:67-92`, topic list `:188-216`). It also POSTs the native dependency (`src/lib/aiur/agent_runner/tool_executor.ex:245-260`).
- The poll-side binder `auto_subscribe_for_dependency/2` (`issue_sync.ex:1579`) is inert on GitHub: the list poll never populates `blocked_by` (comment at `auto_subscriptions.ex:238-247`). So today a Build Order dependent gets **no** blocker subscriptions unless its agent calls `aiur_declare_blocker` itself.
- Mid-turn drain already treats `blocker:auto` bindings as direct blockers and drains `branch.push`, `branch.force-push`, `pr.merged`, `agent.unblocked`, `agent.decision.*` (`auto_subscriptions.ex:263-372`). Binding at dispatch therefore gives mid-turn delivery for free.
- Dispatch holds any `todo` ticket with a non-terminal `blocked_by` (`dispatcher.ex:1402-1420`, `dispatch_policy.ex:857`, `:987`). The hydrated blockers are in hand at that point and are not written back to the poll snapshot.
- A fresh ticket branch starts at the live `origin/<base>` tip (`workspace/checkout.ex:36-45`, `:118-128`). Only the prewarm materialize path calls it (`workspace/materialize.ex:20-23`); cold and SSH paths run operator hooks.
- The prompt has a builder-injected "Authoritative integration branch" block that tells the agent to open PRs with `--base "$AIUR_BASE_BRANCH"` (`prompt_builder.ex:33-35`, `:67-87`). An optimistic dependent must override that.
- `LsRemoteTicker` is the only ticket-branch push publisher. It sees `ref -> sha` only and publishes `ticket.N.branch.push` on any SHA change (`events/ls_remote_ticker.ex:158-202`). It has the previous SHA in `state.refs` but does not publish it. Nothing publishes `ticket.N.branch.force-push`; the skill says so (`emit-and-subscribe.md:329-332`).
- A GitHub compare call that classifies `ahead` / `behind` / `diverged` already exists in `github/human_review_gate.ex:75-92`.
- The skill and shared prompt model a dependent as *paused until readiness*: "never infer readiness from `branch.push`", resume on `agent.unblocked` or `pr.merged` (`stub-then-fetch.md:24-50`, `shared-agent-instructions.md:116-131`). There is no section for a worker that was *started* on an unmerged blocker.

## Product Contract

### Actors

- **Dependent worker** - the agent dispatched on ticket D while blocker B's PR is open.
- **Orchestrator** - binds subscriptions, picks the start point, records the optimistic start.
- **Blocker worker / Executor** - push review fixes to B's branch, sometimes force-push, eventually merge B.

### Requirements

- **R1 Bind before the first turn.** At dispatch of D, for every non-terminal `blocked_by` blocker, the orchestrator binds exactly the subscription set `aiur_declare_blocker` binds (same topics, same `blocker:auto` / `blockee:auto` reasons). It does not re-POST the dependency; the native edge already exists. Binding completes in the orchestrator before the worker task is spawned.
- **R2 Fail closed on binding.** If binding fails for any blocker of an optimistic dispatch, the dispatch is declined with a distinct reason and retried next cycle. An optimistic worker that cannot hear its blocker must not start.
- **R3 Start on the blocker's code.** When exactly one blocker is unmerged, a fresh ticket branch starts at that blocker's head SHA (the PR head G1 evaluated). When several are unmerged, the branch starts at the base tip and the worker merges each blocker head as its first step. An existing remote ticket branch (re-dispatch) is never moved.
- **R4 Tell the worker regardless of path.** The first-turn prompt carries an "Optimistic start" block naming each unmerged blocker: issue, PR, branch ref, head SHA, and the PR base the worker must use. It tells the worker to verify `git merge-base --is-ancestor <sha> HEAD` and merge the blocker head if that fails. This covers cold, SSH, and re-dispatch paths where R3 could not act.
- **R5 Pull every push.** On each `ticket.B.branch.push` the worker fetches the payload `ref`/`sha`, and at its next safe checkpoint (WIP committed) merges it if the last integrated blocker SHA is an ancestor of the new SHA, then reruns the tests affected by the incoming diff.
- **R6 Rebase on rewritten history.** If the last integrated blocker SHA is *not* an ancestor of the new SHA (the worker's own check is authoritative; `ticket.B.branch.force-push` is the early hint), the worker rebases its own commits with `git rebase --onto <new-sha> <old-sha>`, reruns tests, and updates its draft branch with `--force-with-lease`.
- **R7 Stay stacked and in draft.** With one unmerged blocker the PR targets B's branch; with several it targets the base branch. Either way the PR stays draft and the ticket never moves to `ci-wait` or `human-review` while any blocker PR is unmerged.
- **R8 Park, do not spin.** When D's own work is complete and a blocker is still unmerged, the worker leaves the draft PR, emits `blocked` with `reason: "awaiting_blocker_merge"`, and requests a dependency pause (`pause.request`, `reason: "dependency"`, `blocker_identifier: B`). The existing `pr.merged` / cleared-dependency resume wakes it.
- **R9 After the blocker merges** the worker follows G3's restack procedure (retarget to base, drop the squashed blocker commits). G2 only links to it.
- **R10 Publish force-push.** When a ticket branch moves to a SHA that does not descend from its previous SHA, Aiur publishes `ticket.N.branch.force-push` (same `ref`/`sha`, plus `previous_sha`) in addition to the normal `branch.push`. Every `branch.push` payload gains `previous_sha`.
- **R11 Make it observable.** The running entry records the optimistic start (blockers, ref, SHA at start, primary blocker); the dispatch telemetry point carries it. G4 and G5 read this; G2 does not build their views.

### Success criteria

- A dependent dispatched while its blocker PR is open has the 11 bindings in its SubscriptionStore before its first turn starts (test asserts ordering).
- Its workspace HEAD equals the blocker head SHA on the prewarm path; the first prompt contains the Optimistic start block on every path.
- A non-fast-forward move of a subscribed ticket ref yields one `branch.push` and one `branch.force-push` with `previous_sha`; a fast-forward yields only `branch.push`.
- No dependent PR leaves draft while its blocker PR is open (skill/prompt contract; the hard merge gate is G3's).

### Scope boundaries

- **In:** dispatch-time binding, start point, prompt block, running-entry record, skill + shared prompt text, force-push publication.
- **Out (other areas):** *when* a dependent may start (G1); restack after squash merge and merge-order gate (G3); policy when a blocker closes unmerged and waste metrics (G4); slot priority and whether a parked optimistic worker holds a slot (G5).
- **Out (deferred):** a tool-level refusal of `aiur_set_ticket_state(ci-wait|human-review)` while a blocker is unmerged. G3's merge-order gate is the hard stop; a tool guard can follow if agents ignore the prompt.

### Key decisions

| ID | Decision | Reason |
| --- | --- | --- |
| KD1 | Reuse `AutoSubscriptions.subscribe_for_declared_blocker/2` for dispatch-time binding. | Same topics and reasons as the agent tool, so mid-turn drain, unbinding on edge removal, and `direct_blockers_for` work unchanged. No second topic list to drift. |
| KD2 | Bind for every non-terminal blocker at every dispatch, not only optimistic ones. | Idempotent and cheap (0-3 blockers). A `pr_merged` dependent whose blocker issue is still open (merged-open grace) also benefits. Fail-closed applies only to optimistic dispatch. |
| KD3 | Start point via `Checkout`, plus the prompt block as the universal fallback. | Prewarm materialize is the common local path and the only one Aiur controls; hooks own the cold/SSH paths. The prompt's ancestry check makes every path converge. |
| KD4 | One unmerged blocker: PR base = blocker branch. Several: PR base = base branch. | A PR has one base. Matches Kevin's "keep the PR based on the blocker" for the common chain and stays honest for fan-in. |
| KD5 | Blocker ref/SHA come from G1's gate evidence; fallback `BranchRefStore.latest/1`; none -> decline. | G1 already read the blocker PR to decide the trigger; re-reading costs budget and can disagree. `BranchRefStore` is the validated ls-remote view. |
| KD6 | Merge on fast-forward pushes; rebase `--onto` on rewritten history. | Merging a rewritten branch duplicates the blocker's commits and creates false conflicts. Rebase of a draft, unreviewed branch rewrites nothing a reviewer saw. |
| KD7 | Agent's local ancestry check is authoritative; `branch.force-push` is a hint. | The daemon classification can fail (API budget, 404); the worker has the objects after fetch. Order of the two events then does not matter. |
| KD8 | Force-push detection by GitHub compare (`previous...new`), asynchronous, only for refs that have a `branch.force-push` subscriber. | Reuses an existing call shape. One REST call per push of a ticket someone depends on, not per push fleet-wide. Rejected: daemon-side `git fetch` + `merge-base` (object store and fetch cost on the poller), firehose `PushEvent.forced` (firehose no longer publishes ticket pushes and drops them), agent-only detection (no fleet signal for G4). |
| KD9 | Keep publishing `branch.push` on a force-push; add `branch.force-push` beside it. | `BranchRefStore`, unblock corroboration, and the Executor's rework signal key on `branch.push`. Replacing it would break them. |
| KD10 | No G2 config flag. | G2 acts only when G1 dispatches optimistically; G1's default `pr_merged` keeps it inert. Force-push publication is scoped to subscribed refs and is safe on by default. |
| KD11 | A finished optimistic worker parks with a dependency pause. | Reuses the existing `pr.merged` / cleared-dependency resume. Slot accounting of that pause is G5's call. |

### Interfaces assumed from other areas

- **From G1 (start trigger).** The dependency gate at `dispatcher.ex:1402` returns, for a dispatchable ticket, the list of blockers that are open but satisfied by the trigger, each with `identifier`, `pr_number`, `head_ref`, `head_sha`, and `merged?`. Assumed shape: `{:dispatch, %{optimistic_blockers: [blocker_evidence]}}` (empty list = ordinary dispatch). G2 consumes it in `dispatch_issue_with_dependency_check/5`. If G1 names it differently, only the adapter at that call site changes.
- **To G3 (stacking safety).** G2 writes `running_entry.optimistic_start = %{blockers: [%{identifier, pr_number, ref, sha_at_start}], pr_base: ref | :base_branch, started_at}` and the skill sends the worker to G3's restack section on `ticket.B.pr.merged`. G3's merge-order gate is the hard guard for R7.
- **To G4 (failure + waste).** `ticket.N.branch.force-push` with `previous_sha`, and the `optimistic_start` record / dispatch telemetry fields, are G4's inputs for "optimistic work redone".
- **To G5 (capacity).** The parked optimistic worker (R8) is a dependency pause; G5 decides whether it reserves a slot.

## Approaches considered

1. **Orchestrator binds + starts on blocker branch + prompt block (chosen).** Covers both "auto-subscribed" and "starts on the blocker's code" with existing mechanisms.
2. **Prompt-only: tell the worker to call `aiur_declare_blocker` itself.** Zero orchestrator change, but the first turn runs without subscriptions, a forgetful agent stays deaf, and the tool re-POSTs a dependency that already exists. Rejected: Kevin asked for auto-subscription.
3. **Daemon-maintained integration branch (challenger).** Aiur itself merges every blocker push into the dependent's branch. Highest automation, but the daemon would resolve conflicts in an agent's workspace mid-turn. Rejected: conflict ownership belongs to the worker.

## Open questions for Kevin

- None blocking G2. One product preference recorded as an assumption: optimistic dependents rewrite their **draft** branch with `--force-with-lease` after a blocker force-push (recommended: allow, because no reviewer has seen a draft).

## Tickets and plans

| Ticket | Plan | Requirements |
| --- | --- | --- |
| BQ-G2-1 Bind blocker events and start on the blocker branch at optimistic dispatch | `plan-dispatch-binding-and-start-point.md` | R1-R4, R11 |
| BQ-G2-2 Teach the worker the optimistic-start loop (skill + shared prompt) | `plan-agent-skill-optimistic-start.md` | R5-R9 |
| BQ-G2-3 Publish ticket branch force-push events | `plan-publish-force-push.md` | R10 |

No in-area blocking links: BQ-G2-2 is keyed on the prompt block and is inert until BQ-G2-1 ships; BQ-G2-3 is independent. Cross-area: BQ-G2-1 needs G1's dependency-gate change (optimistic blocker evidence).
