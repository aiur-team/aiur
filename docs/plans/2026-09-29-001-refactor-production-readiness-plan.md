---
title: "Evidence-led Aiur refactor - Plan"
date: "2026-09-29"
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
origin: docs/brainstorms/2026-09-29-aiur-refactor-requirements.md
---

# Evidence-led Aiur refactor - Plan

## Goal Capsule

**Objective:** Reduce no-progress time and unnecessary complexity while preserving Aiur's human-operated and agent-operated modes. Give each durable state and failure one owner, remove redundant paths, and bring every tracked text file under the 500-line hard limit.

**Authority:** User directions and AGENTS.md govern implementation; this plan uses the corrected 60-claim audit, all 32 review units, the 216-feature inventory and the frozen `3339b887` source census as evidence. The guard and GitHub cache dashboard removals are pending release PRs #2840/#2841, not savings from this future refactor. Finding IDs below resolve to `docs/research/refactor-2026-09-26/review/findings.json`.

**Readiness:** This is a detailed proposed program, still `requirements-only`. The branch-tip contextual privacy audit is complete; new evidence must be checked before publication. Current-head incidence checks, a complete >500-file owner map, degraded CODEOWNERS trust policy and first package seam require resolution before the affected code units can be launched. The causal timeline identifies local prewarm/dependency point causes, while historical duration shares remain unassigned; the plan measures progress prospectively.

## Product Contract

### Summary

Aiur should make an actionable ticket or PR advance without silent stalls, and tell the Executor exactly what is waiting, failed or uncertain. The refactor should simplify ownership before extracting packages, preserve observed behavior, and account for actual code removed separately from code moved.

### Problem Frame

The corrected retained model contains 108 gaps of at least 30 minutes totaling 727.73 hours, but the bins do not prove who caused each gap. Agent transcripts contain 12,768 short continuation turns taking about 20 measured turn-hours, concentrated in a few threads. The frozen review has 986 canonical findings after preserving 1,033 source IDs; the feature inventory has 216 entries. A source-reference graph joins 35 of 36 proposed boundaries, while Orchestrator shares a 100-field state across lifecycle reducers. These facts support narrower authority and recovery contracts; they do not by themselves prove a package split or a net LOC saving. Sources: `docs/research/refactor-2026-09-26/synthesis/problem-map.md`, `docs/research/refactor-2026-09-26/synthesis/claim-question-audit.md`, `docs/research/refactor-2026-09-26/review/code-review.md` and `docs/research/refactor-2026-09-26/features/feature-inventory.md`.

### Requirements

**Progress and truth**

- R1. Preserve both operating modes: a human drives the CLI, or a coding agent acts as Executor while the human stays in conversation.
- R2. Expose actionable work, waiting for a person, provider unavailability, stale evidence, unknown state and uncertain delivery as distinct states with observed age.
- R3. Make ticket lifecycle transitions, review/rework, CI, pause, capacity and redispatch follow one accountable decision path with a durable result.
- R4. Replace unconditional normal continuation with a condition-driven wait and relevant wake, without reducing accepted ticket throughput.

**Durability and external boundaries**

- R5. Preserve identity, ordering, acknowledgements and idempotency across event, command and review delivery, including restart and ambiguous outcomes.
- R6. Keep the workspace/process lifecycle correct on Linux and Darwin and isolate stop/reap operations to one Aiur instance.
- R7. Keep GitHub reads complete, monotonic and budget-aware across pagination, truncation, webhook failure and cache invalidation; measure any claimed saving on live traffic and a counted population.
- R8. Preserve native Muse and existing backend capabilities during shared extraction; Gemini follows its post-release ticket.

**Simplification and delivery**

- R9. Give each feature a keep, simplify, merge, cut or externalize decision with current usage, indirect reachability and a challenged removal path.
- R10. Remove duplicate authorities and obsolete paths when extracting a component; never claim code movement, a disabled optimization or conditional gross deletion as measured saving.
- R11. Enforce a final 500-physical-line maximum for every tracked UTF-8 text file, including tests, docs, skills, generated and vendor text; prefer 200 or fewer lines with a cohesion rationale above 200.
- R12. Carry docs with changed CLI, config, environment or user surface behavior, and verify user-visible paths with the real foreground CLI/TUI.
- R13. Make each behavior-changing regression test fail when its production hunk is reverted in a clean worktree; retain the existing coverage floor and Dialyzer gate.
- R14. Publish current-head source evidence, unresolved conditions, privacy-safe review records and before/after physical LOC for each implementation phase.

### Actors and key flows

- F1. The Executor sees a ticket become actionable, follows an attention to its evidence, acts once, and sees accepted delivery or a named uncertainty.
- F2. A worker starts in its isolated workspace, receives a message, pauses or restarts, and resumes with the same ticket and process ownership.
- F3. A developer changes one owning component, runs targeted and repository gates, and records behavior preserved plus net text-line change.

### Acceptance examples

- AE1. A rework label arrives while a lifecycle fence is open: the ticket has one visible pending cause, a bounded retry, and an accepted dispatch after the fence closes. Evidence: `docs/research/refactor-2026-09-26/gaps/gap-analysis.md` #2678 and findings `orch-a-01`, `orch-b-02`.
- AE2. A publisher or subscriber restarts with an event in flight: delivery preserves order and cursor; no buffered event is discarded behind a newer one. Evidence: `events-webhooks-executor-01`.
- AE3. A former owner renews after lease expiry and successor claim: the old owner cannot regain owner status. Evidence: `events-webhooks-executor-02`.
- AE4. A GitHub issue has more than 100 comments or a response is truncated: the agent receives complete, explicitly incomplete or failed context, never a success-shaped first page. Evidence: `github-a-04` and `fixes-06`.
- AE5. A tracked UTF-8 text file has 500 lines: the final gate passes; at 501 it fails and names the path/count. At 201, review records a cohesion reason; an edited baseline debt file cannot grow.
- AE6. A paused Muse or Codex worker has a queued Executor message: foreground `scripts/aiurdev --test` chat shows one delivered message and the expected response through the TUI.
- AE7. A proposed cut with `none-found` use is blocked until dynamic, config, transcript, packaging and operator evidence plus replacement checks are complete.

### Scope boundaries and outstanding questions

The program begins after the 0.0.6 guard/dashboard removal release and refreshes the census on merged main. It does not re-add deletion gates or the GitHub cache page. Gemini CLI support is a separately queued post-release implementation. Package extraction is conditional on behavior-preserving seams; a count of packages is not a success measure.

Blocking before code work on the affected boundary: current-head source and exposure validation; all oversized-file owner/disposition assignments; degraded CODEOWNERS trust behavior; which durable journal failures stop writes versus permit a retry; and the first package seam's startup/failure contract. The completed branch-tip privacy audit must be repeated for new public evidence. Historical gap duration causality is unresolved, not permission to guess a causal saving; use `docs/research/refactor-2026-09-26/synthesis/causal-gap-attribution.md` for measured point cases and limits.

## Planning Contract

### Key Technical Decisions

- KTD1. Use the 500-line gate for every tracked text file, with a visible migration ledger and no permanent vendor/generated exemption. (session-settled: user-directed — chosen over an advisory-only cap: the user required automated enforcement.) Source: `docs/research/refactor-2026-09-26/synthesis/file-size-analysis.md`.
- KTD2. Exclude the local deletion guard and GitHub cache dashboard from the refactor baseline after their release PRs merge. (session-settled: user-directed — chosen over retaining these surfaces: the user explicitly ordered both removed before publication.) Sources: `docs/research/refactor-2026-09-26/features/feature-inventory.md` and PRs #2840/#2841.
- KTD3. Start with ownership and typed outcomes; split repositories only when process startup, state, recovery and test contracts can move intact. The static graph is not an extraction proof. Source: `docs/research/refactor-2026-09-26/codebase/feature-boundaries.md`, `docs/research/refactor-2026-09-26/synthesis/architecture-verification.md`.
- KTD4. Keep read models derived from one field owner with timestamp/freshness. Do not build separate status/dashboard/cache authorities. Source IDs: `orch-b-01`, `loose-2-02`, `web-rest-02`, `web-occ-07`.
- KTD5. Keep store-specific durability rules. A failed derived projection may be rebuilt; a failed authoritative journal append cannot be silently accepted. Source IDs: `loose-1-02`, `loose-1-03`, `platform-misc-09`, `loose-4-04`.
- KTD6. Reconcile external mutation outcomes before retrying. Keep GitHub admission, pagination and monotonic resource writes in their existing owning layers until one tested replacement is ready. Source IDs: `github-b-02`, `github-b-03`, `github-a-04`.
- KTD7. Count all tracked physical text lines with LF-separated lines, blank/comment lines and an unterminated final line included; classify binary, do not double-count a symlink target. At 201 lines request a cohesion reason, not an automatic split. Source: `docs/research/refactor-2026-09-26/synthesis/file-size-analysis.md`.
- KTD8. A savings claim needs a running-system baseline, units, a counted reachable production population and a before/after result. The frozen 17,944-line candidate footprint is conditional gross deletion, not a forecast. Source: `docs/research/refactor-2026-09-26/features/loc-reduction.md` and AGENTS.md.

### Sequencing and package decision

`U0` freezes the implementation base and owner map. `U1` addresses confirmed P0 paths and tests before broad extraction. `U2`–`U6` repair owning contracts with characterization tests. `U7` evaluates cuts and candidate package seams after the contracts exist. `U8` retires all 500-line debt across code, tests, docs, skills and shipped assets. `U9` runs complete acceptance and records net LOC. Each unit lands in a reviewable PR or small PR series; the next unit takes the merged main, not a months-old branch.

Possible eventual package seams are GitHub access, agent/backend runtime, lifecycle/Executor state, and presentation. They are options, not four preapproved repositories. The first seam is chosen by counted cross-boundary calls, startup ordering, failure isolation and reversibility; file movement without an eliminated dependency is deferred. Source IDs and ownership conflicts are collected in `docs/research/refactor-2026-09-26/synthesis/report-wide-contradictions.md`.

### Risks and validation gates

| Risk | Gate |
| --- | --- |
| A false causal reading produces a large speculative rewrite. | Use prospective actionable-demand and accepted-progress measures; preserve the 60-claim corrections and mark historical attribution uncertain. |
| A cut erases indirect use. | Challenge `none-found` against configs, dynamic references, packaging, docs and real CLI/TUI behavior before deleting. |
| New helper modules raise LOC and cycle count. | Require one owner, deleted duplicate path, dependency edge diff and before/after physical LOC. |
| A new line gate strands legacy files. | Transitional debt ledger blocks new/increased >500 files; universal gate only after zero debt; no permanent exceptions. |
| A privacy-sensitive corpus leaks into public artifacts. | The branch-tip contextual audit is complete; repeat source-level review for each new public ticket or evidence artifact. This plan carries aggregate counts and source IDs only. |
| A merged fix never runs. | Compare source HEAD, assembled release stamp and running process; use foreground CLI/TUI acceptance on latest main. |

## Implementation Units

These are proposed units. Readiness remains blocked by the Goal Capsule gates; no product-code work is authorized by this research-only branch.

| Unit | Owner boundary and primary files | Depends on |
| --- | --- | --- |
| U0 | Evidence/baseline: `docs/research/refactor-2026-09-26/`, `scripts/`, CI | 0.0.6 publication |
| U1 | Opencode and instance stop: `src/lib/aiur/opencode/`, `src/lib/aiur/open_ai_compat/`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh` | U0 |
| U2 | Ticket lifecycle: `src/lib/aiur/orchestrator/`, `src/lib/aiur/current_run_membership/` | U0, U1 |
| U3 | Event/claim delivery: `src/lib/aiur/events/`, `src/lib/aiur/executor/` | U2 |
| U4 | Agent/backend runtime: `src/lib/aiur/agent_runner/`, `src/lib/aiur/claude/`, `src/lib/aiur/codex/` | U2, U3 |
| U5 | GitHub access: `src/lib/aiur/github/`, `website/docs-app/apis/github.md` | U0, U2 |
| U6 | Decision, usage and durable status: `src/lib/aiur/decision_store.ex`, `src/lib/aiur/usage_aggregate/`, `src/lib/aiur_web/` | U2, U3 |
| U7 | Feature cuts and package seams: `docs/research/refactor-2026-09-26/features/`, candidate subsystem paths | U4, U5, U6 |
| U8 | File-size debt migration: all 359 frozen >500 tracked text paths, refreshed on main | U0–U7 |
| U9 | Full system acceptance and net LOC census: `scripts/aiurdev`, `src/browser/`, packaging | U1–U8 |

### U0. Refresh evidence and establish the size gate

**Goal:** Recheck privacy for any new public evidence, inspect current main after release, map every >500 path to a component and chosen disposition, and publish a fresh text-file census. **Files:** `docs/research/refactor-2026-09-26/synthesis/`, `scripts/`, `.github/workflows/ci.yml`. **Approach:** Recheck P0/P1 source and reachable population; re-count every tracked path; install a transitional CI gate that fails new or enlarged >500 text files. **Tests:** 500/501, 200/201, blank and unterminated lines, generated/vendor, binary/symlink, and edited baseline debt. **Exit:** owner ledger complete; new evidence passes privacy review; counts and CLI/release identity recorded.

### U1. Close current P0 paths without a new deletion policy

**Goal:** Authenticate every Opencode completion branch, scrub raw GitHub tokens from OpenAI-compatible command sandboxes, and scope stop/reap pidfiles to the addressed instance. **Files:** `src/lib/aiur/opencode/bridge.ex`, `src/lib/aiur/open_ai_compat/command_runner.ex`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh` and corresponding tests in `src/test/aiur/`. **Evidence:** `agent-backends-oc-01`, `agent-backends-oc-02`, `nonelixir-shell-01`. **Tests:** unauthorized marker with coalesced text cannot send; sandbox env contains no PAT; stopping instance A leaves instance B's live agent and pidfile intact. **Exit:** focused tests mutate red/green; no new GitHub App gate or PR deletion status check.

### U2. Give lifecycle one owner

**Goal:** Make labels, provider delivery, review/CI head evidence, fences and slot leases produce one desired ticket state and a recorded transition. **Files:** `src/lib/aiur/orchestrator/issue_sync.ex`, `src/lib/aiur/orchestrator/dispatcher.ex`, `src/lib/aiur/orchestrator/pause_resume.ex`, `src/lib/aiur/orchestrator/rate_limit_fallback.ex`, `src/lib/aiur/current_run_membership/` and tests under `src/test/aiur/orchestrator/`. **Evidence:** `orch-a-01`, `orch-b-02`, `orch-b-08`, `platform-misc-03`; corrected #2678/#46 gap cases. **Tests:** stale/unjoinable terminal ticket, parked rework with a closed fence, failed label write amid multiple tickets, lease after restart and capacity release. **Exit:** every stuck state has one owner, cause, age and bounded recovery; no second label writer remains.

### U3. Preserve event and claim ordering

**Goal:** Advance a cursor only after ordered delivery and durable acknowledgement, prevent former-owner renewal, and make action receipts distinct from observation. **Files:** `src/lib/aiur/events/subscription_store.ex`, `src/lib/aiur/executor/claims.ex`, `src/lib/aiur/executor_wake_inbox.ex` and related tests. **Evidence:** `events-webhooks-executor-01`, `events-webhooks-executor-02`, `loose-4-04`. **Tests:** buffered event/new mailbox interleaving, successor claim then former renewal, corrupt journal tail and restart replay. **Exit:** no silent drop or double owner in injected sequences; attention reports unknown/action-pending honestly.

### U4. Simplify agent turn and backend lifecycles

**Goal:** Use condition-driven continuation; settle pause once for TurnLoop and QueueDrain; share only backend session lifecycle that has identical safety semantics. **Files:** `src/lib/aiur/agent_runner/`, `src/lib/aiur/pause_containment.ex`, `src/lib/aiur/claude/`, `src/lib/aiur/codex/`, `src/lib/aiur/muse/` where present on the implementation base, and corresponding tests. **Evidence:** `agent-runtime-01`, `agent-runtime-02`, `agent-backends-cc-04` and corrected `agents-01`–`agents-03`. **Tests:** blocked turn does not loop until its condition changes; paused process remains contained; queued message delivered exactly once; Muse capabilities and unsupported actions remain explicit. **Exit:** count normal continuation turns and accepted work before/after; no unmeasured quota-saving claim.

### U5. Make GitHub outcomes complete and monotonic

**Goal:** Use one complete issue-comment reader, one CODEOWNERS grammar and team resolver, typed truncated/held outcomes, and monotonic resource writes. **Files:** `src/lib/aiur/github/comments.ex`, `src/lib/aiur/github/code_owners.ex`, `src/lib/aiur/github/resource_store.ex`, `src/lib/aiur/github/transport.ex`, `src/lib/aiur/github/quota.ex`, `src/lib/aiur/codeowners.ex`, and `website/docs-app/apis/github.md`. **Evidence:** `github-a-01`, `github-a-04`, `github-a-07`, `github-b-02`, `github-b-03`. **Tests:** 101+ comments, incomplete page and rate hold, stale deposit racing newer write, ambiguous review mutation, degraded team lookup under the chosen trust rule. **Exit:** measured live request population and credential-side rates accompany any claimed saving; no new dashboard cache page.

### U6. Align durable decisions, usage and status

**Goal:** Separate authoritative journal failures from rebuildable projections; re-subscribe aggregates after ledger restart; give CLI/web a shared complete status read model with age. **Files:** `src/lib/aiur/decision_store.ex`, `src/lib/aiur/usage_aggregate/store.ex`, `src/lib/aiur/orchestrator/status_report.ex`, `src/lib/aiur_web/operator_control_center/` and tests. **Evidence:** `loose-1-02`, `loose-1-03`, `telemetry-usage-04`, `orch-b-01`, `web-rest-02`, `web-occ-07`. **Tests:** failed append versus failed JSON projection, ledger restart, nondefault field projection, unknown cap and loader timeout. **Exit:** no success-shaped fallback or stale-as-current value; CI and dashboard do not create competing status authorities.

### U7. Cut duplicate paths and choose package seams

**Goal:** Revalidate 216 feature decisions on merged main; implement only cuts with observed replacement/migration evidence, and extract one stable seam at a time. **Files:** source paths recorded per ID in `docs/research/refactor-2026-09-26/features/features.json`; candidate first seams in `src/lib/aiur/github/`, `src/lib/aiur/agent_runner/` and `src/lib/aiur/orchestrator/`. **Evidence:** `docs/research/refactor-2026-09-26/features/feature-inventory.md` and `docs/research/refactor-2026-09-26/synthesis/report-wide-contradictions.md`. **Tests:** config/CLI/docs parity, dynamic caller and package entry-point checks, old versus new behavior characterization. **Exit:** each cut deletes its old owner; each extraction names startup, state, recovery and failure isolation; report moved and removed lines separately.

### U8. Retire the universal file-size debt

**Goal:** Reach zero tracked UTF-8 text paths above 500 with cohesive responsibility splits and a 200-line review preference. **Files:** every refreshed debt-ledger path, including `src/test/`, `docs/`, `.claude/`, `packages/`, `website/`, CSS and vendored text. **Evidence:** `docs/research/refactor-2026-09-26/synthesis/file-size-census.json` and `docs/research/refactor-2026-09-26/features/loc-reduction.md`. **Tests:** universal gate, each extracted responsibility's behavior tests, generated artifact regeneration or dependency replacement. **Exit:** 500 passes and 501 fails on all tracked text; no permanent exclusions, no `part_1` line-slice modules and no added coverage-ignore entries.

### U9. Prove the whole release and account for actual removal

**Goal:** Run full required CI and real latest-main CLI/TUI/browser acceptance with multiple agents, then publish a before/after tracked-text census. **Files:** `scripts/aiurdev`, `src/browser/`, `packaging/npm/`, operator docs and the plan's evidence ledger. **Tests:** complete `mix lint`, format, test/coverage, Dialyzer, browser harness and package checks, plus foreground `scripts/aiurdev --test` opened agent chat and Executor message via TUI. **Exit:** rendered user-visible output captured, current release identity confirmed, all hard-size debt zero, net LOC reported by source/test/docs/generated with moved lines excluded, and abandoned experimental code removed.

## Verification Contract

| Gate | Command or evidence | Applies to |
| --- | --- | --- |
| Source and dependency scan | `rg` all changed symbols/callers in `src/lib` and `src/test`; refresh frozen review citations on current main | Every unit |
| Focused and affected tests | From `src/` run focused `mix test <files>` and `mix aiur.affected_tests`; include sibling test files | Each behavior unit |
| Mutation proof | In an isolated clean worktree, revert each guarded production hunk; the exact added test fails, restore hunk and it passes; record commands/results in PR | Every new regression test |
| Required CI | From `src/` run `mix format --check-formatted`, `mix lint`, `mix test`, `mix dialyzer` as applicable; required GitHub CI includes sharded coverage and browser | Every PR / integrated main |
| UI and package | Run `npm test` in `src/browser/` where affected, package layout checks and docs build where surfaces change | U4–U9 |
| Real manual acceptance | From the Executor repo, launch foreground `scripts/aiurdev --test` in wrapper tmux, interact with agent list/chat input, capture pane output and stop/clean up | User-visible behavior and U9 |
| Size and savings | Recount every tracked UTF-8 text path; transitional and final 500-line gate; actual before/after net LOC by area; credential-side live measurements for any GitHub saving | U0, U5, U7–U9 |

Tests should assert values and effects, not permissive maps or constants. A claimed saving must include units, baseline, current population and merge-time activation. A removed feature's docs and tests change in the same PR. No manual acceptance claim is valid from logs or HTTP alone.

## Definition of Done

- D1. All ten units have merged as reviewed, behavior-preserving PRs, with every source-ID-specific defect either fixed and mutation tested or explicitly deferred with a reason and owner.
- D2. The Executor and agents complete the accepted foreground CLI/TUI scenarios, including Muse, pause/resume, event delivery and multi-agent progress, on a release built from latest main.
- D3. Every tracked UTF-8 text path is at most 500 lines; files above 200 carry a cohesion rationale; generated/vendor paths have a concrete disposition; the universal gate is required in CI.
- D4. The feature ledger records current use and challenged decisions; retained behavior remains reachable, and cut features leave no dead config, CLI, docs or package entry points.
- D5. The before/after census reports source, test, docs and generated text lines; net change is measured, conditional candidates remain labeled, and relocated lines are not claimed as removed.
- D6. Each new regression test has a recorded red/green production-hunk reversal; full CI, Dialyzer, browser, docs and package gates pass for relevant changes.
- D7. Contextual private-source review is complete before implementation-ticket promotion; uncertainty in historical causal claims remains explicit.
- D8. No experimental dead ends, duplicate helpers or second authorities remain from the migration; operator-facing docs agree with final behavior.
