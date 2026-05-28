---
title: Aiur — agent progress emits with time-based percent
status: ready-for-planning
created: 2026-05-27
related: docs/brainstorms/2026-05-27-aiur-pre-merge-polish-requirements.md (R2)
---

# Agent progress emits with time-based percent

## Problem frame

After PR #130 the agent list has a progress-bar column (`Aiur.ProgressTracker` + `progress_by_id` in `AgentList.App` + bar renderer at `elixir/lib/aiur/agent_list/renderer.ex`) that reads `%{percent, label}` samples from `ticket.<id>.agent.progress` events. The plumbing works. What's missing: the **agent-side emit**. Today no agent emits progress; the column is empty for every row.

The brainstorm `2026-05-27-aiur-pre-merge-polish-requirements.md` R2 specified a percent-of-work model on a configurable time cadence. Two refinements anchor this brainstorm:

1. **Time-based, not output-based.** The percent represents *remaining wall-clock time* on the agent's current phase, not "% of code written" or "% of tests passing". Agents are bad at estimating output completion; they have a much better sense of "how long is this whole thing going to take".
2. **Cleanup-aware.** The estimate must include the agent's expected post-implementation work — code-review feedback turnaround, CI fixes, rework loops. Without this the bar reads "5 minutes to PR" at the moment the agent finishes typing code and then sits at 80% for an hour while review iterations happen.

## Users and value

**Users:** operators running multi-agent runs via the aiur TUI.

**Value:** a glanceable answer to *"how long until each agent is done?"* — calibrated against the work that ACTUALLY happens (code + review + CI + rework), not just the optimistic "writing code" window.

Secondary value: emit cadence is sparse enough that agent token cost stays bounded (key constraint from operator).

## Acceptance examples

### R1. Per-phase time-based percent

- **R1.1** When the agent enters a phase (`phase.brainstorm.start` / `phase.plan.start` / `phase.work.start` / `phase.review.start`), it ALSO emits `ticket.<id>.agent.progress` with `%{percent: 0, label: "<phase>: <one-line plan and rough total minutes>"}`.
- **R1.2** The `percent` reflects wall-clock progress through the agent's *full expected timeline*, not just the current phase. e.g., at `phase.work.start` the agent emits `0%` only if no prior phases have run; if brainstorm + plan are already done it emits ~30% (those two phases' wall-clock share of the whole).
- **R1.3** Within a phase, the agent emits an update **only when its estimate shifts materially** (e.g., CI failed unexpectedly, blocker emerged, scope grew). NOT on a time interval. Threshold: a shift of ≥15 percentage points OR a ≥50% change in remaining-time estimate.
- **R1.4** When a phase ends (`phase.<name>.end`), the agent emits a corresponding progress sample reflecting where the cumulative timeline now sits.
- **R1.5** The label string is short (≤ 80 chars) and human-readable. Format: `"<phase>: <what's left> (~<est> remaining)"`. Example: `"review: applying CI fixes (~10m remaining)"`.

### R2. Cleanup-aware estimate

- **R2.1** When estimating remaining time, the agent must include — and call out in its `label` — the full tail of post-code work it expects for THIS ticket: code-review iterations, CI fixes, rework, manual verification, anything else known. There is no default magnitude — a one-line typo fix may have ~zero tail, a cross-cutting refactor may have hours of it. The point is *honesty*, not a fixed budget.
- **R2.2** The shared agent prompt teaches: "your code-typing phase is rarely the long pole. When you set a remaining-time estimate, name the tail you're budgeting for (e.g., 'expect ~3 review rounds for the auth changes' or 'no review tail expected — single-line typo'). Don't reflexively pad; don't reflexively skip."
- **R2.3** When CI fails or a reviewer asks for non-trivial changes, the agent emits a fresh estimate even if it falls below R1.3's threshold — surprising delays are exactly when the operator wants a visible update.

### R3. Emit budget

- **R3.1** Per turn cap: maximum 2 `progress.*` emits. Beyond that the `emit_event` tool returns an error and the agent's prompt teaches "you're emitting too often; one phase boundary + one mid-phase correction per turn is enough".
- **R3.2** Per-ticket lifetime expectation: roughly 8-15 progress emits across a full ticket (4 phase-starts + 4 phase-ends + maybe 2-7 mid-phase corrections). Roughly one tool call per turn on average — sparse compared to existing tool-call volume.

### R4. Operator surfaces

- **R4.1** The agent-list progress bar column already consumes `%{percent, label}` samples — no renderer change.
- **R4.2** The `Latest` column already shows the most recent event message; the progress event's `label` field surfaces there too.
- **R4.3** No alerts.yaml entries — progress events are silent. (Future Ticket B may map specific phase ends to sounds, but that's out of scope here.)

## Out of scope (explicit non-goals)

- **Numeric percent-of-code-written.** Agents can't estimate it reliably; replaced entirely by time-based.
- **Orchestrator-derived progress** (reading git commits + plan checkboxes to infer percent). Considered, but the agent already has the best information about its own remaining timeline; redundant inference is carrying cost without proportional value.
- **Cross-ticket aggregation** (e.g. "all three sandbox tickets are 60% through"). Per-ticket only.
- **Time-interval cadence** (every N seconds). Replaced by estimate-shift threshold (R1.3) to keep token cost low.
- **Dashboard panel rendering of progress.** Deferred to Ticket C (separate PR).
- **Auto-replacement of `phase.*` events.** Progress events RIDE ALONGSIDE phase events — they don't replace them. Phase events stay as boundary markers; progress events carry the percent + label.

## Resolved questions

| Question | Answer |
|---|---|
| Add new `progress.*` vocab or reuse existing? | Reuse `agent.progress` topic that the existing brainstorm + ProgressTracker already support. No new vocabulary. |
| Emit on time interval or estimate-shift? | Estimate-shift only (R1.3). Time intervals waste tokens when nothing changed. |
| Output-based or time-based percent? | Time-based (R1.1). Cleanup-aware (R2.1). |
| Auto-emit from orchestrator? | No (out of scope). Agent has the best info. |
| Cap per turn? | 2 emits / turn (R3.1). |
| Render where? | Existing bar + Latest column (R4.1, R4.2). |

## Open questions for planning

- **Storage of the agent's initial estimate.** The agent emits "this will take ~30 minutes" at the start; later turns need to remember that to derive percent. Options: (a) the agent recomputes percent each turn from wall-clock start vs current estimate, (b) the orchestrator stores the latest emit and decays percent over time. Lean (a) — simpler, agent already has wall-clock awareness via continuation count + workpad timestamps.
- **Phase weighting.** Should brainstorm count as 10% of the timeline, plan 20%, work 50%, review 20%? Or let the agent emit absolute percent freely? Lean: let the agent emit freely; provide GUIDANCE in the prompt ("review + CI usually ≥ ⅓ of total") but no enforcement.
- **Workpad reference.** The agent's first-turn estimate could be persisted in the `## Agent Workpad` comment so a continuation turn picks up the same anchor. Decide during planning.

## Manual test

Three-ticket sandbox (#99, #100, #101):

1. Run `aiur --test`. All three agents start.
2. Within 30 seconds of `phase.work.start`, each agent emits its first `progress` event with a non-zero percent (because brainstorm + plan phases preceded it).
3. Each agent's progress-bar column ticks up over the ticket lifetime — never goes backward without an emitted re-estimate, never sits at 100% before the PR is merged.
4. After at least one CI failure or review iteration, the agent emits a downward revision (e.g., from 75% → 60%) with a label naming the cause.
5. Per-ticket total emit count stays in the 8-15 range across the full life.

## Scope boundaries

### Deferred for later

- Plan-driven progress (% of plan checkboxes complete) — useful but only when a plan exists.
- Multi-agent aggregation views.
- Dashboard panel rendering of progress samples.
- Persisting estimates across orchestrator restarts.

### Outside this product's identity

- Progress as a project-management feature (Jira-style burndown). aiur's identity is per-agent realtime, not historical reporting.

## Related

- `docs/brainstorms/2026-05-27-aiur-pre-merge-polish-requirements.md` R2 — earlier brainstorm sketch that this refines (anchored output-based percent on a time cadence; replaced here).
- Issue #68 — phase emoji rendering (uses the same `phase.*` events; complementary, not blocking).
- `elixir/lib/aiur/progress_tracker.ex` — orchestrator-side sampling + ETA derivation (already shipped on PR #130).
- `elixir/lib/aiur/codex/dynamic_tool.ex` — `emit_event` tool definition with vocabulary allowlist (needs `progress.*` cap added per R3.1).
- `elixir/prompts/shared-agent-instructions.md` — shared agent prompt; needs the R2.2 cleanup-aware teaching + R1.5 label format.
