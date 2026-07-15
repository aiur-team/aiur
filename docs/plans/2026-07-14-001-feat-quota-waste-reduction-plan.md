---
title: "feat: Aiur quota-waste reduction (cut cold re-runs and wasted turns)"
type: feat
status: active
date: 2026-07-14
origin: docs/brainstorms/2026-07-14-aiur-quota-waste-reduction-requirements.md
---

# feat: Aiur quota-waste reduction (cut cold re-runs and wasted turns)

## Overview

Five focused changes to the Aiur orchestrator that cut the two biggest empirical quota
sinks — **cold re-runs** (avg ~16 dispatches/ticket; #1091 = 85) and **wasted turns at
heavy effort** (`terra:xhigh` = 45% of cost). Implemented in impact order. The
reasoning-effort tiering lever is config-only and shipped as an operator note, not code.

---

## Problem Frame

Aiur bills on a flat $200 ChatGPT-Pro weekly quota, so quota headroom is throughput.
Two months of `~/.codex` session analysis show quota is burned mostly on cold re-dispatches
that re-run planning, and on stuck/long sessions at top reasoning effort. See origin:
`docs/brainstorms/2026-07-14-aiur-quota-waste-reduction-requirements.md` and
`docs/token-reduction/RESEARCH-SPIKE.md`.

---

## Requirements Trace

- R1. Program measured via the `~/.codex` analysis: dispatches/ticket and quota-cost/merged-ticket must fall.
- R2–R4. T1 — cold rework dispatch yields a continuation prompt oriented from the workpad + review feedback, not a cold re-plan.
- R5–R6. T2 — a `human-review` ticket keeps its worktree so `thread/resume` hits.
- R7. T3 — stalled-but-streaming agent is paused + flagged, not run to cap.
- R8. T4 — turn caps scale by complexity tier.
- R9. T5 — a script emits the scoped affected-test command deterministically.

**Origin actors:** A1 (Aiur daemon), A2 (Codex worker), A3 (human Executor).

---

## Scope Boundaries

- The four token tools (ccusage / Serena / context-mode / caveman) — separate program.
- Per-token pricing tricks (Flex / `service_tier`) — verified no-op under ChatGPT-sub auth.
- Prompt compression / semantic response caching — down-ranked.
- Model/provider change — out of scope.
- Reasoning-effort tiering ships as an **operator config note** (Operational Notes), not a unit.

---

## Context & Research

### Relevant Code and Patterns
- `src/lib/aiur/agent_runner/turn_prompt.ex` — `build_turn_prompt/4`; turn-1 has only `resumed` + cold branches today. `issue` (with `.state`, `.labels`) and `opts` (`:resumed`) are both already passed in from `src/lib/aiur/agent_runner/turn_loop.ex:54`.
- `src/lib/aiur/agent_runner/turn_loop.ex` — turn loop; `active_issue_state?/1` + `normalize_issue_state/1` show the state-normalization pattern to reuse for detecting `rework`.
- `src/lib/aiur/orchestrator/runtime_watchdog.ex` — current watchdog (duration + codex-stream inactivity only).
- `src/lib/aiur/orchestrator/agent_teardown.ex` — agent teardown / workspace reaping on deactivation (T2 target).
- `src/lib/aiur/config.ex` — `agent_max_turns/0` (line 310) reads `settings!().agent.max_turns`.
- `src/lib/aiur/config/schema/agent_validation.ex` — existing **complexity routing** + complexity_prompts map normalization/validation; mirror this for `max_turns_by_complexity`.

### Institutional Learnings
- `docs/token-reduction/RESEARCH-SPIKE.md` (this branch) — verified levers + the billing reframe.
- Empirical: `#1091` 85 cold dispatches; `terra:xhigh` 9% sessions / 45% cost; cached re-send = 69% of weighted cost.

---

## Key Technical Decisions

- **Branch T1 inside `build_turn_prompt/4` on normalized `issue.state`** rather than threading a new flag — the issue is already in scope, keeping the change local and testable.
- **T1 handles only the *cold* rework case.** A rework that is a real thread-resume (`opts[:resumed]`) already gets `resumed_turn_prompt/0`; the new branch is for `state==rework AND not resumed`.
- **T4 mirrors the existing complexity-routing map** (`agent_validation.ex`) for consistency, falling back to the flat `agent.max_turns` when a tier is unset.
- **T3 pauses + flags, never auto-kills** — a deep-analysis turn with no commits must not be killed.

---

## Open Questions

### Resolved During Planning
- Is `issue.state` available in `build_turn_prompt/4`? Yes — passed from `turn_loop.ex:54`.
- Where does `max_turns` originate? `config.ex:310 agent_max_turns/0`.

### Deferred to Implementation
- Exactly how the daemon surfaces unresolved review-thread bodies at dispatch time for T1/R3 — if not already in `opts`/issue, T1 v1 may orient from the workpad + a generic "address the review feedback" instruction and thread the concrete review text in a follow-up. Decide when wiring `turn_loop.ex`.
- The precise reap trigger in `agent_teardown.ex` on deactivate-to-`human-review`, and whether `$CODEX_HOME` is persistent across the ticket lifecycle (T2).
- The watchdog's turn-boundary hook point and cheapest git-progress sample (T3).

---

## Implementation Units

- [x] U1. **Rework-continuation prompt (no cold re-plan)** — *flagship*

**Goal:** A cold rework dispatch gets a continuation-style turn-1 prompt that forbids re-running brainstorm/plan and orients from durable state, instead of the full cold prompt.

**Requirements:** R2, R3, R4 · advances R1.

**Dependencies:** None.

**Files:**
- Modify: `src/lib/aiur/agent_runner/turn_prompt.ex`
- Test: `src/test/aiur/agent_runner/turn_prompt_test.exs` (create if absent)

**Approach:**
- In `build_turn_prompt(issue, opts, 1, max_turns)`: if `opts[:resumed]` → `resumed_turn_prompt()` (unchanged). Else if `issue.state` normalizes to `rework` → new `rework_turn_prompt/1`. Else → `PromptBuilder.build_prompt/2` (unchanged cold path).
- `rework_turn_prompt/1`: instructs the agent NOT to re-run ce-brainstorm/ce-plan, to read the existing `## Agent Workpad` and address the unresolved review feedback, with the escape hatch (may re-plan if it records why in the workpad). Reuse the state-normalization helper pattern from `turn_loop.ex`.

**Execution note:** Implement test-first — assert prompt selection per (state, resumed) before writing the branch.

**Patterns to follow:** the existing `resumed_turn_prompt/0` prose + `normalize_issue_state/1` in `turn_loop.ex`.

**Test scenarios:**
- Happy path: `issue.state="rework"`, `opts` without `:resumed` → prompt contains the rework-continuation guidance and does NOT invoke the full cold `PromptBuilder` prompt / does not instruct brainstorm+plan.
- Happy path: `issue.state="rework"`, `opts[:resumed]=true` → returns the resumed prompt (rework-resume already handled).
- Edge case: `issue.state="todo"` (or any non-rework active state), not resumed → returns the cold `PromptBuilder` prompt unchanged (no regression).
- Edge case: state casing/normalization (`"agent:rework"` vs `"rework"`) resolves to the rework branch.
- Edge case: continuation turn (turn_number > 1) is unchanged for a rework ticket.

**Verification:** turn_prompt tests pass; a cold rework dispatch no longer emits the cold-start prompt.

---

- [ ] U2. **Preserve Codex rollout + worktree across human-review dwell**

**Goal:** A completed runner that deactivates to `human-review` keeps its CoW worktree so the Codex thread stays resumable; add a retention ceiling for disk safety.

**Requirements:** R5, R6 · advances R1.

**Dependencies:** U1 (compounds it; not a hard code dependency).

**Files:**
- Modify: `src/lib/aiur/orchestrator/agent_teardown.ex` (and/or the workspace reaper it calls)
- Test: `src/test/aiur/orchestrator/agent_teardown_test.exs` (create/extend)

**Approach:**
- **CORRECTION (found during impl):** the worktree is already NOT reaped on `human-review`. `agent_teardown.ex` `deactivate_running_issue/2` keeps the running entry and only frees the slot; only the terminal done/cancelled path (`terminate_running_issue/3` → `WorkspaceCleanup`) reaps. So the plan's original premise is void.
- **Revised lever:** cold reworks happen because resume doesn't fire, not because the worktree is gone. Resume is driven by `SessionResume`/`SessionHandle` (`agent_runner/session_lifecycle.ex`, `session_resume.ex`): `opts[:resumed]` is set only when a persisted `SessionHandle` exists for the identifier+backend and `CodingAgent.resumable?` holds. The real work is: (a) ensure the `SessionHandle` (codex thread id) survives a `human-review → rework` re-dispatch, and (b) confirm the codex rollout under `$CODEX_HOME` isn't evicted before resume, adding a retention ceiling for disk safety. This is a deeper, live-dispatch change — re-scope before implementing.

**Test scenarios:**
- Happy path: agent completes with issue state `human-review` → worktree path still exists after teardown; slot released.
- Edge case: agent completes into a terminal state (`done`/`cancelled`) → worktree IS reaped (unchanged).
- Edge case: retention ceiling reached → oldest preserved worktrees/rollouts are swept.

**Verification:** a ticket parked in `human-review` can be resumed (thread/resume hits) rather than cold-restarted.

---

- [ ] U3. **Deterministic affected-test selection script** (origin T5)

**Goal:** Replace the agent's per-turn "reason over the diff to pick tests" with a script that prints the exact scoped `mix test` command.

**Requirements:** R9 · advances R1.

**Dependencies:** None.

**Files:**
- Create: `scripts/affected-tests`
- Modify: `.aiur/prompt.md` (point the pre-PR gate at the script)
- Test: `src/test/aiur/scripts/affected_tests_test.exs` OR a shell test under `scripts/` (choose per repo convention)

**Approach:**
- Map changed `src/lib/aiur/X.ex` → `src/test/aiur/X_test.exs` (near-1:1 convention), expand dependents via `mix xref graph --sink`, union with `mix test --stale`, emit `mix test --max-cases 4 <files>`. Document the validated blind spots (Gettext `.po` needs `@external_resource`; `Application.get_env` runtime config) so `make ci` remains the authoritative full gate.

**Execution note:** Validate `--stale` behavior against this repo's Gettext + `Application.get_env` usage before trusting scoped selection (origin deferred question).

**Test scenarios:**
- Happy path: a diff touching one module maps to its `_test.exs` and prints a runnable scoped command.
- Edge case: a module with no direct test file falls back to the xref-expanded set (no empty command).
- Edge case: a config/`.po`-only diff → the script signals "run full suite" rather than silently under-selecting.

**Verification:** the script emits a correct scoped command on a sample diff; prompt.md references it.

---

- [ ] U4. **Git-progress stall watchdog** (origin T3)

**Goal:** Detect an agent that streams but makes no repo progress and pause + flag it before it burns to the cap.

**Requirements:** R7 · advances R1.

**Dependencies:** None.

**Files:**
- Modify: `src/lib/aiur/orchestrator/runtime_watchdog.ex`
- Test: `src/test/aiur/orchestrator/runtime_watchdog_test.exs` (create/extend)

**Approach:**
- Add a progress dimension sampled at turn boundaries: capture commit count / `git diff --shortstat` in the worktree; if unchanged across K consecutive turns while the codex stream is active, transition the ticket to paused + emit an attention flag for the Executor. K is tunable; never auto-kill.

**Test scenarios:**
- Happy path: progress advances between samples → no flag.
- Error/waste path: no git progress across K turns while stream active → pause + Executor flag emitted.
- Edge case: a single long deep-analysis turn (below K) → no premature flag.
- Edge case: stream already inactive (existing duration path) → existing behavior unchanged.

**Verification:** a synthetic no-progress agent is flagged at K; a progressing one is not.

---

- [ ] U5. **Complexity-scaled turn caps** (origin T4)

**Goal:** Cap turns per complexity tier so trivial tickets stop sooner.

**Requirements:** R8 · advances R1.

**Dependencies:** None.

**Files:**
- Modify: `src/lib/aiur/config/schema/agent_validation.ex` (add `max_turns_by_complexity` map normalization/validation, mirroring complexity routing), `src/lib/aiur/config.ex` (resolver), and the turn-cap read site feeding `turn_loop.ex`.
- Test: `src/test/aiur/config/agent_validation_test.exs` + `src/test/aiur/config_test.exs` (extend)

**Approach:**
- Add optional `agent.max_turns_by_complexity` (tier → pos_integer), validated like the existing complexity map. Resolver returns the tier value for the issue's complexity label, falling back to flat `agent.max_turns` when unset. No behavior change when the map is absent.

**Test scenarios:**
- Happy path: `complexity:1` with map `{1: 3}` → effective cap 3.
- Edge case: tier not in map → falls back to `agent.max_turns`.
- Edge case: map absent entirely → identical to today (flat cap).
- Error path: non-positive / non-integer tier values rejected by the changeset (mirror existing validation).

**Verification:** config tests pass; a `complexity:1` ticket caps at the configured lower value.

---

## System-Wide Impact

- **Interaction graph:** U1 changes only prompt *selection* (no new callers); U2 touches agent teardown/slot release; U4 adds a watchdog transition that emits an existing attention/pause signal; U5 changes the cap value read before the turn loop.
- **State lifecycle risks:** U2 must still release the agent slot when it skips worktree reaping (don't leak a busy slot). U4 must not double-pause a ticket already paused by the duration path.
- **Unchanged invariants:** cold non-rework dispatch (U1 else-branch), terminal-state reaping (U2), flat `max_turns` when the map is unset (U5) all behave exactly as today.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| U1 rework prompt lacks the concrete review text at v1 | Orient from workpad + generic "address review feedback"; thread exact review bodies as a follow-up once the dispatch-time data path is confirmed. |
| U2 skips reaping but leaks the agent slot | Release the slot independently of worktree removal; assert slot release in tests. |
| U2 unbounded `~/.codex` / worktree growth | Retention ceiling (config/constant) with oldest-first sweep. |
| U4 false-positive on deep-analysis turns | Pause + flag only (never kill); require K consecutive no-progress turns. |
| U3 `--stale` under-selects (Gettext / runtime config) | Diff→file map is primary; `make ci` remains authoritative full gate; document blind spots. |

---

## Operational / Rollout Notes

- **Effort-tiering (operator config, not a unit):** `.aiur/config` `agent.routing` already accepts per-tier `backend:model:effort`. Empirically `terra:xhigh` is 45% of cost — trial `medium`/`high` on tiers 1–2, keep `xhigh` on 4–5, and A/B one wave with the `~/.codex` analysis before/after. Note the runtime already emits `high`/`xhigh` (and `sol:max`), so first confirm which effort is actually valid/live before changing.
- **Measurement:** re-run the empirical `~/.codex` extraction after each unit lands to confirm dispatches/ticket and quota-cost/merged-ticket fall (success criterion R1).

---

## Sources & References

- Origin document: `docs/brainstorms/2026-07-14-aiur-quota-waste-reduction-requirements.md`
- Research: `docs/token-reduction/RESEARCH-SPIKE.md`
- Related code: `src/lib/aiur/agent_runner/turn_prompt.ex`, `src/lib/aiur/orchestrator/runtime_watchdog.ex`, `src/lib/aiur/config.ex`
