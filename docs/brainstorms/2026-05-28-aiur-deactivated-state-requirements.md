---
title: "Deactivated agent state (🏁): keep finished tickets visible without holding slots"
type: feat
status: requirements
date: 2026-05-28
---

# Deactivated agent state (🏁) — requirements

## Problem Frame

Today, when an agent finishes its work-iteration (commits, opens PR, marks ready, flips issue label to `agent:human-review`), the issue immediately leaves `active_states` and its row vanishes from the AgentList — even if the bar would otherwise have reached 100% green.

The operator loses three things in that instant:
1. **Visual confirmation that the agent finished cleanly.** No "done" signal lives anywhere visible.
2. **A reactivation surface.** The chat pane, the pause/resume control, and the row's selectable cursor are all gone the moment the label flips.
3. **The work-just-finished context.** "Latest" message, progress samples, and any open attention chips disappear with the row.

The progress-emits work shipped this iteration ([docs/brainstorms/2026-05-27-aiur-progress-event-emits-requirements.md](2026-05-27-aiur-progress-event-emits-requirements.md)) made the bar honest about in-flight progress, but the visual loop never closes — 100% never gets to render because the row's gone.

This brainstorm scopes a new visual + lifecycle state to close the loop: the agent **deactivates** (stops working, releases its slot, frees its chat pane) while the row **stays visible** at 100% with the 🏁 glyph. Standard reactivation triggers (pause/resume, chat input, PR comment) bring it back the same way they would any agent.

---

## Goals

- **G1.** The "finished for now" moment is visible: 🏁 glyph + full green bar in the row's existing position.
- **G2.** Deactivated agents do not hold agent slots — another ticket can take the slot the moment the agent flips to 🏁.
- **G3.** The same three reactivation triggers that wake any agent today also wake a 🏁 agent: pause/resume key, chat input, PR comment.
- **G4.** Resource economy: deactivated tickets do not hold persistent opencode chat panes.
- **G5.** ~~State survives aiur restart: a ticket already in `agent:human-review` on next boot renders as 🏁 immediately, without needing to re-run the agent.~~ **Dropped after implementation.** The 🏁 state only appears for tickets that transition to `agent:human-review` within the current aiur session. Tickets already in `agent:human-review` at boot stay out of the AgentList; flipping their GitHub label back to an active state re-enters them through the normal dispatch path.

---

## Requirements

### R1. Entry to deactivated state

R1.1. The deactivated state is the existing `work_state: :done` (🏁 glyph already mapped at `elixir/lib/aiur/agent_events.ex:172`). No new state enum value is introduced.

R1.2. A row enters `work_state: :done` when **either** of these signals lands:
- The agent's issue label transitions to `agent:human-review` (GitHub firehose `issue.label.added.agent.human-review`).
- The agent emits a progress sample with `percent: 100` (regardless of which `phase.*.end` alert it was paired with — see R6).

R1.3. The 🏁 row remains in the AgentList in its existing sort position. No re-sort.

R1.4. The progress bar renders 10/10 cells + green tint (already shipped — `Aiur.AgentList.Renderer` `progress_cell/2` greens at percent: 100).

R1.5. The row's "Latest" column continues to surface the most recent event message (unchanged).

### R2. Slot economics

R2.1. A `work_state: :done` row does **not** consume an agent slot. The orchestrator's "running" / `Agents: codex (N/M)` count drops by one when the agent flips to 🏁.

R2.2. Distinct from `:paused`: paused agents continue to hold their slot. The orchestrator's pause behavior is unchanged. The new property is specific to `:done`.

R2.3. When a 🏁 row reactivates (R3), it queues for a slot the same way new tickets do — first-available. No preemption of other active agents.

### R3. Reactivation triggers

A 🏁 row transitions back to `work_state: :working` (and re-acquires a slot, queueing if none free) when **any** of these fire:

- R3.1. **Pause/resume key.** Operator selects the row and presses `space`. Same shortcut as standard pause/resume.
- R3.2. **Chat input.** Operator opens the row's chat pane (Enter) and types a message. Reactivation happens on message submit.
- R3.3. **PR comment from outside.** GitHub firehose `pr.commented` event for the row's open PR. (Covers both human reviewers commenting and other agents / bots interacting.)
- R3.4. **Issue label flip back to an active state.** Already-existing behavior: any flip to `agent:in-progress`, `agent:rework`, or `agent:merging` re-activates. Listed here for completeness.

### R4. Chat pane lifecycle

R4.1. When the row enters `work_state: :done`, the opencode chat pane warmed for that ticket is killed (process + tmux pane released). Same teardown path the orchestrator already uses when a ticket leaves the active set.

R4.2. When the operator opens the chat pane on a 🏁 row (Enter), aiur re-warms an opencode slot on demand. The slot warms in the background; the pane shows the "Warming up…" placeholder until ready, then becomes interactive. This matches the existing cold-start pattern.

R4.3. Re-warming the chat pane does **not** by itself reactivate the agent (no codex turn fires). The agent reactivates only on the triggers in R3.

### R5. Persistence across aiur restart — **DROPPED**

~~R5.1. When aiur boots and polls GitHub, any issue with label `agent:human-review` renders as a 🏁 row with 100% green bar.~~ Dropped during implementation. Boot revival was implemented and immediately reverted — the operator prefers a clean list at boot. The `:deactivated` state is per-session: it only exists for tickets the orchestrator personally observed transitioning into `agent:human-review`.

To re-enter a previously-deactivated ticket into the list, flip its GitHub label back to an active state (`agent:in-progress`, `agent:rework`, `agent:merging`) — it then enters via the normal dispatch path.

### R6. Companion fix to the progress prompt

The current shared prompt ([elixir/prompts/shared-agent-instructions.md](../../elixir/prompts/shared-agent-instructions.md)) pairs the 100% emit with `phase.review.end`. Complexity:1 paths legitimately skip the review phase, so the 100% emit never fires. Live test on issue 140 confirmed this gap.

R6.1. Update the prompt: the 100% progress emit is **not phase-specific**. It fires when the agent stops working for this iteration — typically right before flipping the issue label to `agent:human-review`, regardless of which CE phases ran (or didn't).

R6.2. The 100% emit becomes effectively redundant with the label-flip signal (per R1.2) — but emitting it keeps the prompt internally consistent (every phase boundary gets a progress sample, including the final stop-work moment) and gives the agent a chance to write a final cleanup-aware `label` describing what was just shipped.

R6.3. This is a 5-line prompt edit. Land it together with the deactivated-state implementation so the visual signal works end-to-end on the next manual `aiur --test` run.

---

## Acceptance Examples

- **AE1.** Operator runs `aiur --test` on a fresh sandbox. Agent picks up the complexity:1 ticket, emits `percent: 30` at `phase.work.start`, ships the change, marks the PR ready, flips label to `agent:human-review`, emits `percent: 100`. The row's bar fills to 10/10 + green, glyph turns 🏁, `Agents: codex (N/M)` drops by one, opencode chat pane is freed.

- **AE2.** Operator presses Enter on the 🏁 row → chat pane re-warms (cold start visible). Operator types "any thoughts on adding a smoke test?" → message submits → agent reactivates → row's glyph flips to 🟢 (working) → progress bar resets to in-flight % per the agent's next emit.

- **AE3.** Human reviewer leaves a PR comment requesting a change. PR-comment firehose event lands → orchestrator reactivates the agent → row's glyph flips to 🟢 → agent reads the comment, addresses it.

- **AE4.** Three issues are simultaneously in `agent:human-review`. None hold slots. Operator triggers reactivation on all three within a second. Orchestrator queues all three; the first runs immediately, the other two wait for slots to free (per R2.3).

- ~~**AE5.** Operator restarts aiur. On boot, the issue from AE1 (still labelled `agent:human-review` on GitHub) renders as 🏁 with 100% green bar.~~ **Dropped** — per the revised R5, restart drops the 🏁 row. The operator flips the label back to an active state if they want the agent to wake on the next run.

---

## Scope Boundaries

### Deferred for later

- **Sort-on-state-change.** Some operators may eventually want 🏁 rows sunk to the bottom of the list so the top is always actionable. This brainstorm explicitly keeps existing sort; sorting can be a follow-up if pain emerges.
- **"Recently completed" archive panel.** Tickets that have been merged (label flipped to `agent:done` or `agent:cancelled`) still leave the list entirely — that terminal exit is unchanged. A persistent history surface is a separate UX question.
- **Time-out for 🏁 rows.** A deactivated row stays visible forever today. If the operator leaves many 🏁 rows accumulated, the list gets long. Not solving here; consider a "hide 🏁 older than N hours" filter later if needed.

### Outside this product's identity

- **Preemption of other active agents on reactivation.** Reactivation queues — it does not displace working agents. Preemption logic would add a policy surface this orchestrator deliberately doesn't own.
- **Reactivation on arbitrary GitHub events beyond PR comments.** Issue comments (not PR), review-requested events, assignee changes, etc. — out of scope. PR comment is the canonical "someone needs the agent" signal.

---

## Dependencies & Assumptions

- D1. The existing `:done` work_state + 🏁 glyph in `Aiur.AgentEvents.state_emoji/1` are reusable — no new state value to plumb.
- D2. The renderer's bar-green-at-100 path (shipped in `e6eb167`) handles R1.4 unchanged.
- D3. The orchestrator's "active_set" computation in `Aiur.AgentList.App` filters by current label. The change touches the filter to **include** `agent:human-review` rows as 🏁 (but not as slot-holders).
- D4. The orchestrator's slot accounting reads from running-agent count, not from active_set membership. Confirm during planning — if they're coupled today, decouple in the same change.
- D5. The PR-comment reactivation trigger reuses the existing `pr.commented` firehose plumbing from PR #98 / #130. No new event vocabulary.
- D6. The chat-pane "kill and re-warm on demand" pattern already exists for the cold-start case. Reuse the same teardown + warm-up path.

---

## Open Questions for Planning

- **Q1.** Where exactly does the active_set filter live, and is the slot-counter coupled to it? (Quick scan suggested the active_set is in `Aiur.AgentList.App` but slot count is in `Aiur.Orchestrator`. Planning should confirm.)
- **Q2.** Does aiur today expose a clean "reactivate this issue from human-review" entry point, or does each reactivation trigger (chat input, PR comment, pause/resume) have to learn the same transition logic? Planning should pick one canonical transition function.
- **Q3.** When the chat pane is killed on deactivate, does its current transcript / pane history survive? If yes, the operator's re-open feels continuous; if no, a small "session restarted" affordance might be needed. Mostly a planning-time discovery.
- **Q4.** Should the `Agents: codex (N/M)` counter call out deactivated rows separately (e.g., `codex (2/6 active, 3 🏁)`)? Probably not on the first cut — keep the counter strictly about slot consumption. Revisit if operators ask.

---

## Sources & References

- **Predecessor brainstorm:** [docs/brainstorms/2026-05-27-aiur-progress-event-emits-requirements.md](2026-05-27-aiur-progress-event-emits-requirements.md) — the progress-emits work that made the 🏁 visual valuable in the first place.
- **Predecessor plan:** [docs/plans/2026-05-27-002-feat-agent-progress-emits-plan.md](../plans/2026-05-27-002-feat-agent-progress-emits-plan.md) — U1/U2/U3 already shipped; the gap surfaced here is the prompt's pairing of 100% with `phase.review.end` (R6 above).
- **Live-test trace:** Issue #140 / PR #141 on this repo — the run that surfaced the 30% → label-flip → bar disappears flow.
- **Relevant code (recon, not prescription):**
  - `elixir/lib/aiur/agent_events.ex` — `state_emoji/1`, `:done → 🏁` mapping.
  - `elixir/lib/aiur/agent_list/app.ex` — `active_set` computation, `progress_by_id` compaction (lines 510-512 are the spot that drops the row's progress samples on state change).
  - `elixir/lib/aiur/orchestrator.ex` — slot accounting, pause/resume transitions, label-derived work_state.
  - `elixir/local-workflows/WORKFLOW.aiur.local.md` — `active_states` config (currently `todo, in-progress, rework, merging`).
