---
title: "feat: Deactivated agent state (🏁) — keep finished tickets visible without holding slots"
type: feat
status: active
date: 2026-05-28
origin: docs/brainstorms/2026-05-28-aiur-deactivated-state-requirements.md
deepened: 2026-05-28
---

# feat: Deactivated agent state (🏁) — keep finished tickets visible without holding slots

## Overview

When an agent's iteration finishes (commits, opens PR, marks ready, flips label to `agent:human-review`), today the row vanishes from the AgentList because `human-review` is not in `tracker.active_states`. The bar never reaches the 100% green state we just shipped, the operator has no in-list reactivation surface, and the row's "Latest" / progress / attention chips are lost.

This plan adds a **deactivated** lifecycle state. We introduce a new `work_state: :deactivated` atom mapped to the existing 🏁 glyph in `Aiur.AgentEvents.state_emoji/1`. (Earlier drafts proposed reusing `:done`, but ce-doc-review surfaced that `:done` is already overloaded as the broadcast reason in `Aiur.AgentPubSub`, the return tuple from `agent_runner.continue_with_issue?`, and `turn_done_reason` — see "Key Technical Decisions" for the trade-off.) On `agent:human-review`, the orchestrator stops the codex task but keeps the running entry, flagged `:deactivated`. The AgentList retains the row at 100% green; the orchestrator's slot counter excludes `:deactivated` rows so another ticket can take the slot immediately; the opencode chat pane is freed by AttachPool (same path used when an issue stops). Two reactivation triggers — pause/resume (space key) and chat input — funnel through a single canonical `reactivate_issue/2` transition that flips `:deactivated → :working` and queues a new turn. PR review-comment from outside is the third trigger via the existing `ticket.<N>.pr.review_comment` firehose topic.

Companion fix lands in the same pass: the shared prompt's `100% paired with phase.review.end` rule (which a `complexity:1` agent legitimately skipped, surfaced by issue #140's live test) is re-anchored to the stop-work moment so the emit always fires.

---

## Problem Frame

The visual loop the progress-emits work (PR-merged plan `docs/plans/2026-05-27-002-feat-agent-progress-emits-plan.md`) was supposed to close never closes today:

1. Bar honestly shows in-flight % up through `phase.work.*` (shipped).
2. Agent finishes, flips label to `agent:human-review`.
3. Orchestrator's `reconcile_issue_state/4` falls into the `else` branch (state is non-active + non-terminal) and calls `terminate_running_issue` → row drops from `state.running` → `AgentList` summary disappears → all per-id maps (`progress_by_id`, `latest_event_by_id`, `open_attentions_by_id`) get compacted away.
4. The operator sees the row vanish. The 30% bar (or whatever the last sample was) was the last visible signal that the agent ever existed.

Live test on issue #140 (PR #141) confirmed: agent emitted `percent: 30` at `phase.work.start`, shipped the change, flipped the label, **never emitted 100** (because the prompt paired it with `phase.review.end` which a complexity:1 path skips), then the row disappeared. The bar's green-at-100 path that shipped in commit `e6eb167` was never exercised against a real agent.

The fix is two-layered:
- **Lifecycle:** stop terminating the running entry on the `human-review` transition. Keep it, mark `:deactivated`, free the slot + pane, allow standard reactivation.
- **Prompt:** the 100% emit fires on stop-work regardless of which CE phases ran.

---

## Requirements Trace

- R1. (R1, R1.1–R1.5 in origin) Entry to deactivated state: row enters `work_state: :deactivated` when the orchestrator observes the label transition to `agent:human-review`. (See "Key Technical Decisions" — the label is the orchestrator's authoritative trigger; emitted `percent: 100` is the visual confirmation but does not drive orchestrator-side state.) Existing sort preserved; `:deactivated` gets an explicit sort bucket. Bar renders 10/10 green (already shipped). Latest column unchanged.
- R2. (R2.1–R2.3) Slot economics: `:deactivated` rows do not consume an agent slot; `Agents: codex (N/M)` drops on entry. Distinct from `:paused` which still holds a slot. Reactivation queues for a slot (no preemption).
- R3. (R3.1–R3.4) Reactivation triggers: pause/resume key, chat input, **PR review comment** firehose, and any label flip back to an active state. (Issue-body comments are explicitly excluded per the brainstorm's "Outside this product's identity" boundary — see "Scope Boundaries".)
- R4. (R4.1–R4.3) Chat pane lifecycle: pane killed on entry to `:deactivated`, re-warmed on demand when the operator opens the row. Re-warm alone does not fire a new codex turn — only the R3 triggers do. The AgentList paints a transient "rewarming" affordance during the cold-start gap (see U4).
- ~~R5.~~ **Dropped after implementation.** Boot revival was shipped (U6) and immediately reverted on operator feedback — the cluttered list at boot was worse than the missing 🏁 row. The `:deactivated` state is now strictly per-session: only tickets that transition during the live aiur run get the 🏁 row.
- R6. (R6.1–R6.3) Prompt fix: 100% emit is stop-work-anchored, not `phase.review.end`-anchored. Land in the same pass.

**Origin acceptance examples:** AE1 (live end-to-end on `aiur --test`), AE2 (chat-input reactivation), AE3 (PR-comment reactivation — review-comment topic only per scope tightening), AE4 (multiple deactivated rows do not hold slots; queueing on reactivation), AE5 (boot revives 🏁 row from label).

---

## Scope Boundaries

- **Sort-on-state-change** — `:deactivated` rows land in a documented sort bucket (see U4); no sinking to the list bottom in this iteration.
- **"Recently completed" archive panel** — terminal-state exits (`agent:done` / `agent:cancelled`) still remove the row entirely. No persistent history surface in this plan.
- **Time-out for 🏁 rows** — rows stay visible forever. No "hide 🏁 older than N hours" filter.
- **Preemption on reactivation** — reactivation queues, does not displace working agents.
- **Reactivation on arbitrary GitHub events beyond PR review comments** — issue comments (whether on issue body or on the PR body), review-requested events, assignee changes, etc. — out of scope per origin. The canonical "someone needs the agent" signal is the PR review comment (`ticket.<N>.pr.review_comment`), which is the per-line code-review thread topic. (Earlier draft erroneously included `ticket.<N>.issue.commented`; ce-doc-review flagged the contradiction with the origin boundary and the trigger has been removed.)
- **Counter UI breakdown** — `Agents: codex (N/M)` stays strictly slot-based. No `(N active, K 🏁)` breakdown.
- **Per-session dismiss affordance** — no "hide this 🏁 row without touching GitHub" keybind. Operators can flip the GitHub label to `agent:cancelled` to terminate the row.
- **Inspection-only chat affordance** — typing in the chat pane always reactivates. There is no read-only inspection mode in this iteration.
- **Passing PR-comment body into the new turn** — reactivation triggers a fresh turn; the agent re-reads the PR / issue context itself via `gh pr view` / `gh issue view`. No special comment-to-prompt plumbing.
- **Persisting transcripts across kill+re-warm** — opencode pane teardown loses its session transcript. Acceptable per R5.2; re-warmed pane shows the cold-start placeholder until the next event lands.

---

## Context & Research

### Relevant Code and Patterns

- `elixir/lib/aiur/orchestrator.ex`:
  - `reconcile_issue_state/4` (line 552) — the cond that branches on terminal / non-routable / active / else. The **else** branch (line 567-570) is where `human-review` falls today; this is U2's primary edit site.
  - `terminate_running_issue/3` (line 620) — kills the agent task pid, drops the running entry, removes from claimed. Used by both the terminal branch and the else branch. U2 introduces a sibling `deactivate_running_issue/2` that kills the task pid but keeps the entry.
  - `put_running_control_status/3` (line ~2569) — the existing helper for mutating the control map. **Its current guard whitelists `[:paused, :working]` only**, so U2/U5 must either expand the guard or bypass the helper by mutating the entry directly. The plan picks bypass (less surface area for accidental status-leakage from elsewhere in the codebase).
  - `active_running_count/1` (line 1602) and `paused_running_entry?/1` (line 1621) — the existing slot-count exclusion pattern for `:paused`. U3 mirrors for `:deactivated`.
  - `resume_issue/2` (line 2443), `resume_paused_issue/2` (line 2457), `resume_queued_issue/2` (line 2536) — existing pause→resume transitions. U5 adds a sibling `:deactivated → :working` reactivation path.
  - `send_operator_message/2` (line 1673) and `handle_call({:send_operator_message, …})` (line 2077) — chat-input entry point. U5 teaches this path to reactivate a `:deactivated` entry before enqueueing the message.
  - `handle_call({:pause_agent, …})` (line ~2095) — the pause-key path. U5 defines its behavior on a `:deactivated` entry: explicit no-op return `{:error, :already_inactive}` so the operator's mental model stays clean.
  - `enqueue_after_resume/6` (line 2311) — the existing pattern for "queue this delivery, fire the agent when it resumes".
  - `refresh_tracked_set/1` (line ~173) — builds the publisher's "should we accept events for this issue" set from `state.running`. U2 must drop the just-deactivated id from this set so in-flight events from the killed task don't overwrite the synthetic 100 progress sample.
  - `refresh_running_issue_state/2` (line 610) — used by the active-state branch in `reconcile_issue_state/4`. **Today it only updates `:issue`, never calls dispatch.** After U2, a `human-review → in-progress` transition lands an entry with `pid: nil` and `:deactivated` control status; this branch must call `reactivate_issue/2`, not just clear the status (see U5).
- `elixir/lib/aiur/agent_list/app.ex`:
  - Lines 486-492 — `active_ids` filter that drives both AttachPool seeding (line 494) and per-id compaction (lines 502-512). U4 splits this filter into two: `visible_ids` (keeps `:deactivated` rows) for compaction, `slot_ids` (excludes `:deactivated` rows) for AttachPool. `agents_with_content` compaction uses `visible_ids` so the ⚪ glyph is preserved on the deactivated row.
  - Lines 1011-1023 — `emoji_sort_key/1`. U4 adds an explicit `:deactivated` clause documenting the sort bucket (matching `:done`/error bucket so 🏁 sits between 🔴 and ⚫). Default sort behaviour preserved otherwise.
- `elixir/lib/aiur/agent_events.ex`:
  - `state_emoji/1` line 172 — currently `:done → 🏁`. U2 adds a clause `:deactivated → 🏁`. The `:done` mapping stays for the existing turn-completion semantic.
- `elixir/lib/aiur/agent_list/renderer.ex`:
  - `progress_cell/2` — already greens at `percent: 100` (shipped in `e6eb167`). No change.
  - `phase_placeholder/3` (lines 705-719) and `summary_emoji/2` (lines 779-786) — currently bypass the marker system for `:done` rows. U4 adds a `rewarming_ids` MapSet so a row whose pane is mid-cold-start renders with ⏳ + "Warming up…" while the AttachPool spins up. Cleared when the attach_state for the id arrives.
  - `help_body_rows/1` (line ~228) — the legend currently reads `"🏁 agent fully finished"`. U4 updates to `"🏁 awaiting human review — space or chat to reactivate"`.
- `elixir/lib/aiur/events/github_firehose.ex`:
  - `PullRequestReviewCommentEvent` → `ticket.<N>.pr.review_comment` (line 203). **This is the only firehose topic U5 subscribes to**, per the origin's "PR comment is the canonical signal" boundary.
  - `IssueCommentEvent` → `ticket.<N>.issue.commented` (line 184). **Explicitly NOT subscribed** by U5. Issue-body comments (including PR-body comments which GitHub also emits as IssueCommentEvent) do not reactivate the agent.
- `elixir/lib/aiur/events/publisher.ex`:
  - `bot_self_loop?/1` (line ~198) — already drops events where `actor` matches the bot account before fan-out. U5's subscriber inherits this protection automatically; no additional actor-filter code needed.
- `elixir/lib/aiur/github/client.ex`:
  - `fetch_candidate_issues/1` (line ~18) — today fetches only `agent:todo` + `agent:in-progress`. **U6 must add an explicit fetch for `agent:human-review` labelled issues**, otherwise boot revival is dead code (the candidates never reach the orchestrator).
- `elixir/prompts/shared-agent-instructions.md`:
  - The "Progress emits — 1-of-10 estimate at phase boundaries" section (added in commit `dcfee74`) is the U1 edit site. The 100% bullet is currently anchored to `phase.review.end`.
- `elixir/local-workflows/WORKFLOW.aiur.local.md`:
  - `tracker.active_states` (lines 10-14). **Do not add `human-review` to active_states.** The orchestrator's dispatch gate still treats `human-review` as non-dispatchable; the running entry stays put via U2's deactivate path.

### Institutional Learnings

- **`render_state takes explicit` (`memory/feedback_render_state_takes_explicit.md`)** — new state fields on `Aiur.AgentList.App` must be added to `render/1`'s `Map.take/put` pipeline. U4 adds `rewarming_ids` as a state field; the `Map.take` step must list it.
- **`Push don't merge` (`memory/feedback_push_dont_merge.md`)** — push after every commit on this feature branch; final merge to main only on explicit operator approval.
- **`Bug fix TDD` (`memory/feedback_bug_fix_tdd.md`)** — U6 (boot revive) and U2 (deactivate path) are behavioral changes the live test surfaced. Write failing tests first.
- **Live test on issue #140 / PR #141** — concrete repro of the gap. Use the same `aiur --test` flow to verify the full loop end-to-end after each unit lands.

### External References

None — this is a self-contained orchestrator behavior change anchored in existing code patterns.

---

## Key Technical Decisions

- **New `:deactivated` work_state atom, mapped to the existing 🏁 glyph.** Earlier drafts proposed reusing `:done`, but `:done` is heavily overloaded: it is the broadcast reason in `Aiur.AgentPubSub` ("turn completed successfully"), the return tuple from `agent_runner.continue_with_issue?`, the `turn_done_reason` value (line 441), and the renderer's `summary_emoji/2` matches `:done`/`"done"` for terminal-state rendering. Reusing the atom would force every consumer of `:done` to disambiguate "agent has fully finished" from "agent has stopped for now, awaiting review". Adding `:deactivated` is a single new clause in `state_emoji/1` and a single new atom in the work_state enum; the cost is one additional pattern-match call site in the renderer's `summary_emoji/2` and the help-screen legend update.
- **Keep the running entry, kill only the codex task.** A new private `deactivate_running_issue/2` mirrors `terminate_running_issue/3`'s task-teardown but does NOT remove the entry from `state.running`. The entry's `:control` map carries `status: :deactivated`, and the entry's `:pid` field becomes `nil`. **The existing `put_running_control_status/3` helper's guard whitelists only `[:paused, :working]`** — U2 bypasses that helper and mutates the entry's control map directly via `put_in/2`. The narrow whitelist on the helper is preserved (it gates pause/resume control messages, which `:deactivated` is not).
- **Drop the deactivated entry from the publisher tracked set.** `refresh_tracked_set/1` builds the publisher's gate from `state.running`. Without an explicit drop on the deactivate transition, in-flight events from the just-killed codex task (a late progress sample, a queued alert) still pass the gate and broadcast — overwriting the synthetic 100 sample on the bar. U2 calls `refresh_tracked_set/1` after the deactivate transition with the deactivated id excluded.
- **Slot counting is already decoupled from active_states.** `active_running_count/1` walks `state.running` and excludes `:paused` entries; we add `:deactivated` to that exclusion. No coupling to `tracker.active_states` config. (Resolved Q1 from origin.)
- **AgentList filter splits.** Two derived sets from the summaries list:
  - `visible_ids` (the existing `active_ids` semantics, extended to include `:deactivated` rows) drives per-id map compaction including `agents_with_content`.
  - `slot_ids` (the existing `active_ids` semantics, minus `:deactivated` rows) drives AttachPool seeding so panes are freed.
- **Canonical reactivation entry: `reactivate_issue/2`.** A new function in `Aiur.Orchestrator` handles the `:deactivated → :working` transition: clears `control.status`, calls the existing dispatch path. **No `pending_reactivation` flag** — the entry transitions to `:working` immediately and queues against the existing `max_concurrent_agents` gate. If no slot is available, the entry sits in `:working` state without a pid until the dispatcher picks it up on the next tick (same behaviour as a freshly-labelled `agent:todo` ticket). Earlier draft used a flag; ce-doc-review pointed out the existing queue logic already covers this case without new state.
- **Four reactivation triggers, all routing through `reactivate_issue/2`:**
  - Pause/resume control message (`resume_issue/2` detects `:deactivated` and routes).
  - Chat input (`send_operator_message` detects `:deactivated` and routes BEFORE enqueueing the message).
  - PR review comment firehose (`ticket.<N>.pr.review_comment` subscriber matches `:deactivated` entries).
  - Label-flip back to active state. `reconcile_issue_state/4`'s active-state branch must call `reactivate_issue/2` on a `:deactivated` entry rather than `refresh_running_issue_state/2`, because the existing refresh path only mutates `:issue` and never calls dispatch.
- **PR review-comment is the only firehose trigger.** `ticket.<N>.pr.review_comment` is the per-line code-review topic — when a human reviewer leaves an in-PR comment, this fires. `ticket.<N>.issue.commented` (which GitHub also emits for comments on the PR body) is explicitly NOT subscribed per the origin's scope boundary. Re-evaluate after first operator feedback if PR-body comments turn out to be the more common signal.
- **`bot_self_loop?` filter inherited automatically.** `Aiur.Events.Publisher.publish/3` already drops events where `actor` matches the bot account before fan-out. U5's subscriber inherits this protection; no additional actor-filter code needed inside U5.
- **Label is the orchestrator's source of truth for `:deactivated`.** When the agent emits `percent: 100` AND the label transitions to `human-review` (close in time, U1's prompt teaches them to co-occur), the orchestrator-side `:deactivated` transition fires on the label observation. The AgentList paints 100% green from the progress event as soon as it arrives (existing renderer behaviour). If the percent=100 sample arrives first, the bar greens immediately; the row keeps its 🟢 glyph until the next poll's label reconcile fires the `:deactivated` transition. Brief glyph mismatch is acceptable and short-lived.
- **Pause on `:deactivated` is a documented no-op.** `handle_call({:pause_agent, …})` returns `{:error, :already_inactive}` when the entry's control status is `:deactivated`. The space key on a 🏁 row only ever reactivates; it cannot pause a row that has no pid.
- **Boot revival via synthetic entry, gated on an explicit fetch.** When the orchestrator boots, `Aiur.GitHub.Client.fetch_candidate_issues/1` is extended (or a sibling function added) to also fetch `agent:human-review` labelled issues. U6 then materializes synthetic running entries for the subset NOT already in `state.running`. This requires expanding the GitHub fetch surface; the existing fetcher hardcodes `todo` + `in-progress` (line 18-25). Without this expansion, boot revival is dead code.
- **Cleanup-aware honesty is a prompt rule, not a validator.** Carried from the predecessor plan.
- **Single-percentage source of truth: `progress_by_id`.** The renderer already keys on the latest sample's percent value. On `:deactivated` transition, AgentList.App records a synthetic `(100, now)` sample in `progress_by_id` so the bar reads 100 for `:deactivated` rows even when the agent never emitted 100 (e.g., before U1's prompt lands, or for boot-revived rows). On reactivation, the next agent-emitted sample naturally takes precedence (newest-first ring).
- **Re-warm transient visual.** U4 adds a `rewarming_ids` MapSet field on `Aiur.AgentList.App` state. When the operator opens a 🏁 row's chat pane (Enter), the id is added to `rewarming_ids`. While present, `summary_emoji/2` routes through the marker system (showing ⏳) and `phase_placeholder/3` shows "Warming up…" in the LATEST column. The id is cleared from `rewarming_ids` when `attach_state` for the id is populated (pane ready). Per the `render_state takes explicit` memory, this field must be wired through `render/1`'s `Map.take/put` pipeline.

---

## Open Questions

### Resolved During Planning

- **Q1: Active_set filter vs slot counter coupling.** Decoupled today — `active_running_count/1` walks `state.running` directly and excludes `:paused` via `paused_running_entry?/1`. U3 adds the symmetric `:deactivated` exclusion. The orchestrator's `active_state_set/0` reads `tracker.active_states` config but only gates dispatch candidates, not slot counts.
- **Q2: Canonical reactivation transition.** New `reactivate_issue/2` in `Aiur.Orchestrator`. Four callers funnel through it (resume control message, send_operator_message, firehose PR review-comment subscriber, label-flip-active in `reconcile_issue_state`). Each caller detects `:deactivated` state and routes to `reactivate_issue/2` instead of its existing paths.
- **Q3: Chat pane transcript across kill+rewarm.** Opencode pane teardown loses its session transcript — that's a property of the opencode bridge, not new behavior. Acceptable per R5.2. U4 adds the `rewarming_ids` transient visual so the gap is operator-visible.
- **Q4: Counter UI breakdown (`(N active, K 🏁)`).** No. Counter stays strictly slot-based.
- **(post-review) Race: percent=100 + label arrive same tick.** Label is the orchestrator's authoritative trigger; the AgentList paints 100% green from the progress sample independently. Brief glyph mismatch (🟢 + 100% bar before the next poll greens the glyph) is acceptable.
- **(post-review) `pending_reactivation` flag.** Dropped. `reactivate_issue/2` sets `work_state: :working` immediately; the existing dispatch queue + `max_concurrent_agents` gate handles backpressure without a flag.

### Deferred to Implementation

- **Exact place to seed the synthetic `(100, now)` progress sample in `AgentList.App`.** Either in the `running_changed` handler when work_state flips to `:deactivated`, or in the renderer fallback when a `:deactivated` summary has no recent samples. Implementer picks the lower-coupling option. The newest-first ring guarantees reactivation reads the post-reactivation agent emit, not the synthetic 100.
- **Whether to emit a synthetic `phase.review.start` alert when the agent reactivates via PR comment.** Probably not (the agent will emit its own phase alerts on the new turn), but worth confirming during U5 implementation.
- **Stall watchdog behavior on `:deactivated` entries.** `reconcile_stalled_running_issues/1` (line 653) walks `state.running` and restarts entries past the stall timeout. Today the `if is_integer(elapsed_ms) and elapsed_ms > timeout_ms` guard at line 675 silently passes nil-timestamp entries (which `:deactivated` always has) — so the protection is in place by existing code. Verify during U2; no defensive early-return needed unless implementer finds a path where `last_codex_timestamp` could be non-nil on a `:deactivated` entry.
- **Synthetic boot-revived entry `started_at`.** Whether to source from GitHub `updated_at` of the label-add event. The AGE column would otherwise render `0s/0t` for a row that may represent yesterday's work. U4 adds a placeholder branch when `started_at` is nil and work_state is `:deactivated`, rendering `—/—` instead of `0s/0t`.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

State transitions for a running entry (work_state values):

```
                                  ┌──────────────────────────────────┐
                                  │                                  │
                                  ▼                                  │
   :working ──[label→human-review]──▶ :deactivated                   │
      ▲                                                              │
      │                                                              │
      └───[control resume / chat input / pr.review_comment /        ─┘
            label→active]──▶ reactivate_issue/2 ──▶ :working

   :working ──[control pause]──▶ :paused ──[control resume]──▶ :working
```

Slot consumption + pane warmth:

| work_state          | Holds slot? | In running map? | Pane warm?         |
|---------------------|-------------|------------------|--------------------|
| `:working`          | Yes         | Yes              | Yes                |
| `:paused`           | Yes         | Yes              | Yes (unchanged)    |
| `:deactivated` (new)| **No**      | Yes              | **No** (freed)     |
| terminated          | No          | No               | No                 |

The reactivation funnel:

```
   pause/resume key       ──┐
   chat input             ──┼──▶  Orchestrator.reactivate_issue/2  ──▶  dispatch (queue if no slot)
   pr.review_comment      ──┤
   label→active (reconcile)──┘
```

---

## Implementation Units

- [ ] U1. **Re-anchor the 100% emit in the shared prompt (R6)**

**Goal:** Move the `percent: 100` instruction from "paired with `phase.review.end`" to "paired with the moment you stop working for this iteration — typically the same turn you flip the issue label to `agent:human-review`". Add one sentence clarifying it fires regardless of which CE phases ran (no review phase ≠ no 100% emit).

**Requirements:** R6

**Dependencies:** None — ships independently. Lands first so the next `aiur --test` exercise confirms the prompt change against an agent without needing U2-U6.

**Files:**
- Modify: `elixir/prompts/shared-agent-instructions.md`

**Approach:**
- Locate the "1-of-10 scale" bullet list inside the `Progress emits — 1-of-10 estimate at phase boundaries` section. The `100:` bullet currently reads `"emit exactly once, paired with the phase-end alert that closes out your work for this iteration (typically phase.review.end…)"`. Rewrite to `"emit exactly once, right before you flip the issue label to agent:human-review — regardless of which CE phases ran this turn"`.
- Add a one-line corollary under the worked example: "Complexity:1 paths that skip ce-brainstorm / ce-plan / ce-review still emit the 100% sample at the label flip."
- Leave the rest of the section (granularity, cleanup-aware tail, cap) intact.

**Patterns to follow:**
- The existing section style — single bullet per granularity step, one worked example, ≤ 80-char `label` examples.

**Test scenarios:**
- Test expectation: none — prompt prose is documentation, not behavioral code. Verification is reading the rendered prompt and confirming the new wording appears, then running `aiur --test` (after U2-U6 land) to confirm the agent actually emits 100% before the label flip.

**Verification:**
- Render the workflow prompt via `Aiur.PromptBuilder.shared_prompt_prefix/0` and confirm the new wording appears. Live verification: AE1 from origin runs end-to-end.

---

- [ ] U2. **Orchestrator deactivate path — keep the running entry on `human-review`**

**Goal:** When `reconcile_issue_state/4` sees an issue transition into a non-active, non-terminal state that is specifically `agent:human-review`, **deactivate** instead of terminate: kill the codex task, set `control.status: :deactivated` via direct entry mutation (bypassing the `put_running_control_status/3` helper's narrow guard), mark `pid: nil`, drop the id from the publisher tracked set so in-flight events from the killed task don't pass the gate, but keep the entry in `state.running`. All other non-active non-terminal labels continue to terminate as today. Add the `:deactivated → 🏁` clause to `Aiur.AgentEvents.state_emoji/1`.

**Requirements:** R1, R2

**Dependencies:** None — this is the foundation that U3, U4, U5, U6 build on.

**Execution note:** Test-first. Write a `reconcile_issue_state/4` test that constructs a running entry, then flips the label to `human-review`, and asserts the entry survives with `work_state: :deactivated`. Then write the implementation.

**Files:**
- Modify: `elixir/lib/aiur/orchestrator.ex`
- Modify: `elixir/lib/aiur/agent_events.ex` (add the `:deactivated` glyph clause)
- Test: `elixir/test/aiur/orchestrator_test.exs` (extend the existing reconcile tests; add a new `describe "deactivate on human-review"` block)

**Approach:**
- Inside `reconcile_issue_state/4`, add a new clause that matches the `human-review` label specifically. Order it AFTER `terminal_issue_state?` and `!issue_routable_to_worker?` (so terminal still wins and a re-routed entry still terminates) but BEFORE the catch-all `true →` branch.
- `deactivate_running_issue/2` mirrors `terminate_running_issue/3` for the task-teardown half (call `terminate_task(pid)`, demonitor ref) but does not delete from `state.running` / `state.claimed`. Instead, it updates the running entry: `pid: nil`, `ref: nil`, `control: %{status: :deactivated}`, and clears any retry attempts. **Mutate the entry directly via `put_in/3` rather than calling `put_running_control_status/3`** (whose guard whitelist `[:paused, :working]` would silently drop the transition).
- After the entry mutation, call `refresh_tracked_set/1` (or equivalent) so the publisher's gate no longer admits events for the deactivated id. This prevents late events from the dying codex task from overwriting the synthetic 100 bar sample U4 will seed.
- Reconcile-time stall watchdog needs no defensive guard — the existing `is_integer(elapsed_ms)` guard at line 675 silently passes nil-timestamp `:deactivated` entries. Add a code comment at that line noting the invariant.
- Add `:deactivated → "🏁"` clause to `Aiur.AgentEvents.state_emoji/1`. Update the moduledoc above `state_emoji/1` to document `:deactivated` as "agent has stopped working for this iteration; ticket lives at 100% awaiting reactivation" while leaving `:done`'s "agent has fully finished" semantic intact.
- Do **not** change `tracker.active_states` config.
- Logger.info on the transition: `"Issue deactivated (human-review): issue_id=… ; keeping running entry, freeing slot"`.

**Patterns to follow:**
- `terminate_running_issue/3` (line 620) — copy the task-teardown half, drop the state mutation half.
- `paused_running_entry?/1` (line 1621) — same `get_in(entry, [:control, :status])` lookup pattern for matching `:deactivated`.
- Existing `state_emoji/1` clauses — single-line atom → emoji.

**Test scenarios:**
- Happy path: running entry exists for issue N with `control.status: :working`. Reconcile sees label `agent:human-review`. Entry stays in `state.running` with `control.status: :deactivated`, `pid: nil`. Covers AE1's "row's glyph turns 🏁" assertion at the orchestrator level.
- Edge case: running entry already has `control.status: :deactivated`. Reconcile sees same `human-review` label. No-op (entry stays as-is, no spurious task kill).
- Edge case: `terminate_task` raises on a nil pid path. Deactivation must guard against double-deactivate and re-entry.
- Edge case: deactivated entry's id is NO LONGER in the publisher tracked set after the transition. Late events for that id are dropped at the gate. Covers the in-flight-publish risk surfaced by ce-adversarial.
- Error path: terminal label (`agent:done`, `agent:cancelled`) still calls `terminate_running_issue` with `cleanup_workspace=true`. Verify the new `:deactivated` branch does NOT intercept terminal states.
- Edge case: non-active, non-terminal label OTHER than `human-review` (e.g., label removed entirely) still calls `terminate_running_issue(cleanup_workspace=false)` per today.
- Edge case: `!issue_routable_to_worker?` branch fires BEFORE the new `:deactivated` branch, so a re-assigned `:deactivated` issue still terminates.
- Edge case: `state_emoji(:deactivated)` returns `"🏁"`. `state_emoji(:done)` still returns `"🏁"` (existing behaviour preserved).
- Integration: `reconcile_stalled_running_issues/1` over a state with one `:deactivated` entry and one `:working` entry that has stalled. The `:deactivated` entry is left alone; the `:working` entry restarts as expected.

**Verification:**
- All new tests green; existing orchestrator reconcile tests unchanged. `mix test test/aiur/orchestrator_test.exs` and `mix credo --strict` pass.

---

- [ ] U3. **Slot counting excludes `:deactivated` entries**

**Goal:** `active_running_count/1` walks `state.running` and currently excludes `:paused` entries; add the same exclusion for `:deactivated`. The `Agents: codex (N/M)` counter drops by one when a row flips to `:deactivated`, freeing a slot for the next dispatch.

**Requirements:** R2.1, R2.3

**Dependencies:** U2 (needs the `:deactivated` work_state to be set on a running entry).

**Files:**
- Modify: `elixir/lib/aiur/orchestrator.ex`
- Test: `elixir/test/aiur/orchestrator_test.exs` (extend the existing slot-count tests)

**Approach:**
- Add `deactivated_running_entry?/1` mirroring `paused_running_entry?/1` (line 1621). Both check `get_in(entry, [:control, :status])` for the respective atom.
- Change `active_running_entry?/1` (line 1618) to `not (paused_running_entry?(entry) or deactivated_running_entry?(entry))`.
- Verify `should_dispatch_issue?` and related dispatch-gate functions are slot-aware via `active_running_count`; if they use a different counter or hardcoded path, audit and fix in this unit.

**Patterns to follow:**
- `paused_running_entry?/1` and `active_running_entry?/1` (lines 1618-1625) — the exclusion pattern is two lines.

**Test scenarios:**
- Happy path: running map has 3 entries — one `:working`, one `:paused`, one `:deactivated`. `active_running_count/1` returns 1 (working only). Covers AE1's "Agents: codex (N/M) drops by one" claim.
- Edge case: running map has only `:deactivated` entries. `active_running_count/1` returns 0. Dispatch is free to claim new tickets up to `max_concurrent_agents`.
- Edge case: empty running map. Counter returns 0 (existing behavior).
- Integration: with 6/6 slots full and one entry flipped to `:deactivated` mid-poll, the orchestrator's next dispatch tick claims a new ticket from the queue. Covers AE4 ("three issues simultaneously in human-review; none hold slots").

**Verification:**
- New tests green. Manual sanity: in `aiur --test`, after the agent flips to `:deactivated`, the header shows `codex (0/6)` (down from `codex (1/6)`).

---

- [ ] U4. **AgentList — keep `:deactivated` rows visible, free panes, seed bar to 100, transient re-warm visual**

**Goal:** Split the `active_ids` filter at `Aiur.AgentList.App` lines 486-492 into `visible_ids` (keeps `:deactivated` rows so progress / latest / attention chips survive compaction, including `agents_with_content`) and `slot_ids` (excludes `:deactivated` rows so AttachPool frees the warmed opencode pane). Seed a synthetic `(100, now_ms)` sample in `progress_by_id` when a row transitions to `:deactivated`. Add an explicit `:deactivated` clause to `emoji_sort_key/1`. Add a `rewarming_ids` MapSet for the transient pane re-warm visual. Update the help-screen legend.

**Requirements:** R1.3, R1.4, R1.5, R4.1, R4.2, R5.2 (the renderer-side; orchestrator side lives in U2)

**Dependencies:** U2 (needs `:deactivated` running entries to exist).

**Execution note:** Test-first against the seed-progress-on-transition behavior and the `rewarming_ids` lifecycle — both are small new state-management code that's easy to introduce regressions in.

**Files:**
- Modify: `elixir/lib/aiur/agent_list/app.ex`
- Modify: `elixir/lib/aiur/agent_list/renderer.ex` (help legend; `summary_emoji/2` + `phase_placeholder/3` routes for `rewarming_ids`; AGE column placeholder for nil `started_at` on a `:deactivated` row)
- Test: `elixir/test/aiur/agent_list/app_test.exs` (new `describe "deactivated state visibility"` block)
- Test: `elixir/test/aiur/agent_list/renderer_test.exs` (extend existing renderer tests for `:deactivated` glyph + help legend)

**Approach:**
- Around line 486-492, build `visible_ids` from summaries where `status == :running`. Build `slot_ids` from `visible_ids` minus entries where work_state is `:paused` OR `:deactivated`. Pass `slot_ids` to `safely_seed_attach_pool/1`.
- Use `visible_ids` for the `Map.take` compaction at lines 502-512, including `agents_with_content` (so the ⚪ glyph stays on `:deactivated` rows that had transcript content).
- Add `done_summary?/1` and `deactivated_summary?/1` predicates mirroring `paused_summary?/1` at line 910.
- In the `running_changed` handler, detect summaries whose work_state transitioned to `:deactivated`. For each, call `record_progress_sample/2` with a synthetic body `%{percent: 100}` so the renderer reads 100. Reuse the existing `progress_percent/1` + `Aiur.ProgressTracker.record/3` pipeline at lines 726-737.
- Add `:deactivated → 3` clause (same bucket as `:error`) to `emoji_sort_key/1` at line 1011, with a comment documenting the bucket choice.
- Add `rewarming_ids: MapSet.t()` to the `Aiur.AgentList.App` state struct, default `MapSet.new()`. Wire it through `render/1`'s `Map.take/put` pipeline per the `render_state takes explicit` memory.
- On the "Enter pressed on a 🏁 row" input handler, add the id to `rewarming_ids`. On `attach_state` update for an id present in `rewarming_ids`, remove it.
- In `renderer.ex`:
  - `summary_emoji/2`: when the summary's id is in `layout.rewarming_ids`, route through the marker system (⏳) instead of the direct `:deactivated → 🏁` mapping.
  - `phase_placeholder/3`: when the id is in `rewarming_ids`, show "Warming up…" regardless of prior LATEST content.
  - `age_string/1`: when work_state is `:deactivated` AND `started_at` is nil, render `—/—` instead of `0s/0t`.
  - `help_body_rows/1` line 228: change `"🏁 agent fully finished"` to `"🏁 awaiting human review — space or chat to reactivate"`.

**Patterns to follow:**
- The existing `paused_summary?/1` at line 910 — same shape for `done_summary?/1` and `deactivated_summary?/1`.
- The existing `record_progress_sample/2` at line 726 — the seed call mirrors the existing publish-event handler's signature.

**Test scenarios:**
- Happy path: summary list has one `:working` row and one `:deactivated` row. `visible_ids` contains both. `slot_ids` contains only the `:working` row. `progress_by_id` for the `:deactivated` row reads 100. Covers AE1.
- Happy path: a `:working` row with ⚪ glyph (agents_with_content) transitions to `:deactivated`. After the next render, the ⚪ glyph is preserved (or replaced by 🏁 per state_emoji — verify rendering precedence). Covers the agents_with_content compaction fix surfaced by ce-scope-guardian.
- Edge case: summary transitions `:working → :deactivated` mid-frame. The synthetic 100 sample is recorded once; subsequent renders read 100; no duplicate samples accumulate beyond `Aiur.ProgressTracker.@max_samples`.
- Edge case: summary transitions `:deactivated → :working` (reactivation). The progress sample stack is preserved (existing samples + the synthetic 100 remain), but the renderer should display the latest agent-emitted % once the agent emits again. Verify the synthetic 100 doesn't pollute the post-reactivation reading.
- Edge case: row currently `:paused` is not in `slot_ids` (existing behavior preserved). AttachPool still releases the slot for paused rows.
- Edge case: operator presses Enter on a 🏁 row. The id is added to `rewarming_ids`. The next render shows ⏳ + "Warming up…" in the LATEST column.
- Edge case: `attach_state` update arrives for an id in `rewarming_ids`. The id is removed. The next render shows the standard `:deactivated → 🏁` glyph and the actual LATEST content.
- Edge case: a `:deactivated` row with `started_at: nil` (boot revived per U6). The AGE column renders `—/—` not `0s/0t`.
- Edge case: a `:deactivated` row with `started_at` set (deactivated mid-session per U2). The AGE column renders the actual elapsed time.
- Edge case: help screen rendered via `help_body_rows/1` shows the updated legend wording for 🏁.
- Integration: `running_changed` event arrives with a summary list that includes a `:deactivated` row, a `:paused` row, and a `:working` row. Renderer paints all three: `:deactivated` with 🏁 + 10/10 green; `:paused` with ⏸️ + last-sample bar; `:working` with the current marker glyph + agent-emitted bar.

**Verification:**
- New tests green. Visual verification on `aiur --test`: 🏁 row visible at 100%; `Agents: codex (N/M)` reflects the slot drop; no `(no agents running)` placeholder appears when a deactivated row exists; help screen legend reads new wording; pressing Enter on a 🏁 row shows ⏳ "Warming up…" until the pane is ready.

---

- [ ] U5. **Canonical `reactivate_issue/2` + four trigger wirings (R3)**

**Goal:** Introduce a single `reactivate_issue/2` in `Aiur.Orchestrator` that handles `:deactivated → :working` transitions: clears `control.status`, dispatches immediately if a slot is free or sits in `:working` state until the next dispatcher tick claims it (same backpressure as a freshly-labelled ticket). Wire four triggers to call it: (a) pause/resume control message detects `:deactivated` and reactivates instead of resuming; (b) `send_operator_message` detects `:deactivated` and reactivates before enqueueing; (c) a new firehose subscriber matches `ticket.<N>.pr.review_comment` only (NOT `issue.commented`); (d) `reconcile_issue_state/4`'s active-state branch routes through `reactivate_issue/2` on a `:deactivated` entry rather than `refresh_running_issue_state/2`. Pause-key on a `:deactivated` entry returns `{:error, :already_inactive}`.

**Requirements:** R3.1, R3.2, R3.3, R3.4

**Dependencies:** U2 (the `:deactivated` entry must exist), U3 (the slot count must release on `:deactivated` so reactivation can fire immediately when capacity exists).

**Files:**
- Modify: `elixir/lib/aiur/orchestrator.ex`
- Test: `elixir/test/aiur/orchestrator_test.exs` (new `describe "reactivate_issue"` block)

**Approach:**
- New private `reactivate_issue(state, issue_id)`: looks up the running entry; if `control.status == :deactivated`, set `control.status: :working` (direct `put_in/3` mutation, same reason as U2). Re-add the id to the publisher tracked set via `refresh_tracked_set/1`. Then call the existing dispatch path. If no slot is free, the entry remains `:working` and pidless; the next dispatcher tick picks it up via the existing queue logic (no new `pending_reactivation` flag).
- Pause/resume integration: in `resume_issue/2` (line 2443), detect if the running entry's `control.status == :deactivated` and route to `reactivate_issue/2` instead of the existing `resume_paused_issue`. Standard `:paused → :working` resume path stays unchanged.
- Pause-key on `:deactivated`: in `handle_call({:pause_agent, …})` (line ~2095), detect `:deactivated` and return `{:error, :already_inactive}` without sending a control message to the (nil) pid.
- Chat input integration: in `handle_call({:send_operator_message, identifier, payload}, …)` (line 2077), if the running entry is `:deactivated`, call `reactivate_issue/2` first, then enqueue the operator message via the existing path. The agent picks it up when its turn fires.
- PR review-comment firehose subscription: add an orchestrator subscriber to `ticket.+.pr.review_comment` ONLY. The `bot_self_loop?` filter in `Aiur.Events.Publisher` already drops self-comments; U5's subscriber inherits this protection without writing its own actor filter. On receipt, extract the issue number, look up the running entry, and if `:deactivated` → call `reactivate_issue/2`. For non-`:deactivated` entries, no-op silently (no log spam).
- Label-flip-to-active reactivation: in `reconcile_issue_state/4`, the active-state branch (line 564) currently calls `refresh_running_issue_state/2` which preserves the running entry but never calls dispatch. After U2, this entry may have `control.status: :deactivated` and `pid: nil`. Add a branch BEFORE `refresh_running_issue_state` that detects `:deactivated` and routes to `reactivate_issue/2`. The standard `refresh_running_issue_state` path stays unchanged for `:working`/`:paused` entries.

**Patterns to follow:**
- `resume_issue/2` and `resume_paused_issue/2` (lines 2443, 2457) — the control flow shape.
- `enqueue_after_resume/6` (line 2311) — how queued items are passed during a state transition.
- The existing firehose subscription path used by the cross-ticket events foundation (PR #98 / #130) for subscribing to `ticket.*` patterns.

**Test scenarios:**
- Happy path: entry is `:deactivated` with 1 of 6 slots used by another `:working` entry. `reactivate_issue/2` flips to `:working`, dispatches immediately. Covers AE2's "agent reactivates → row's glyph flips to 🟢".
- Happy path: entry is `:deactivated`, all 6 slots full. `reactivate_issue/2` flips to `:working`, entry sits pidless until the next dispatch tick claims a freed slot. Covers AE4's queueing claim.
- Happy path (PR review-comment): firehose publishes `ticket.140.pr.review_comment` with actor `alice` (not aiur). Subscriber matches, looks up entry 140 (`:deactivated`), calls `reactivate_issue/2`. Covers AE3.
- Edge case: firehose publishes `ticket.140.issue.commented`. Subscriber **does not match** (we don't subscribe to this topic). No reactivation. Covers the scope-tightening fix.
- Edge case: firehose publishes `ticket.140.pr.review_comment` with actor matching aiur's bot account. `Aiur.Events.Publisher.bot_self_loop?` drops it BEFORE the subscriber sees it. Covers the inherited filter.
- Edge case: firehose publishes `ticket.140.pr.review_comment` on an entry that is `:working` (not `:deactivated`). Subscriber no-ops silently.
- Edge case: chat input lands on a `:working` entry. `send_operator_message` flows through the existing queue path (no reactivation). Covers backward compatibility.
- Edge case: chat input lands on a `:paused` entry. `send_operator_message` flows through the existing `enqueue_after_resume` path. Covers backward compatibility.
- Edge case: pause-key pressed on a `:deactivated` entry. `handle_call({:pause_agent, …})` returns `{:error, :already_inactive}`. The space-key only ever reactivates a 🏁 row; it cannot pause one.
- Edge case: PR comment lands on an entry that's been removed from `state.running` (e.g., label was already flipped to terminal). Subscriber gracefully no-ops.
- Edge case: 20 PR review comments arrive on the same `:deactivated` entry in rapid succession. The first reactivation flips to `:working`; the subsequent 19 see `:working` and no-op silently. Exactly one reactivation log line.
- Edge case: deactivated entry's id is re-added to the publisher tracked set on reactivation, so the agent's first publishes from the new turn pass the gate.
- Integration: label flips `agent:human-review → agent:rework`. `reconcile_issue_state/4` detects `:deactivated` entry, calls `reactivate_issue/2` directly (not `refresh_running_issue_state/2`). Entry re-enters dispatch.

**Verification:**
- All new tests green. Live verification via `aiur --test`: after the 🏁 row appears, press space to reactivate (R3.1); open the row's chat pane and type a message (R3.2); leave a PR review comment from the GitHub UI (R3.3). Each should bring the row back to `:working`.

---

- [x] ~~U6.~~ **Boot revival — reverted on operator feedback (was R5)**

**Goal:** When the orchestrator boots and polls GitHub, the existing fetcher only returns `agent:todo` + `agent:in-progress` issues. Extend the fetcher (or call a sibling function) to also return `agent:human-review` issues, then materialize a synthetic running entry (`pid: nil`, `control.status: :deactivated`, no claim) for each one NOT already in `state.running`. The row renders as 🏁 + 100% green immediately. No new turn fires.

**Requirements:** R5.1, R5.2, R5.3

**Dependencies:** U2 (the `:deactivated` work_state must be a known shape on running entries), U4 (the synthetic 100 progress seed lives in AgentList.App and must accept boot-time entries).

**Execution note:** Test-first against the boot reconciliation behavior; bugs here are hard to reproduce from live tests.

**Files:**
- Modify: `elixir/lib/aiur/github/client.ex` (add `fetch_human_review_issues/0` or extend `fetch_candidate_issues/1` to optionally include `human-review`)
- Modify: `elixir/lib/aiur/orchestrator.ex` (boot pass; synthetic entry construction)
- Test: `elixir/test/aiur/github/client_test.exs` (new fetcher coverage)
- Test: `elixir/test/aiur/orchestrator_test.exs` (new `describe "boot revival from human-review"` block)

**Approach:**
- In `Aiur.GitHub.Client`, add a function that queries the `agent:human-review` label. The cleanest shape is `fetch_human_review_issues/0` (mirror the existing `fetch_candidate_issues/1` query shape, just different labels). Alternatively, extend `fetch_candidate_issues/1` to take a `labels` option and pass `["human-review"]` from the orchestrator boot pass. Either pattern is acceptable; the implementer picks the lower-touch option.
- In the orchestrator's boot dispatch cycle (`initial_dispatch_cycle: true` at line 109), after the existing `fetch_candidate_issues/1` pass, call the new fetcher and materialize synthetic entries for each returned issue NOT already in `state.running`:
  ```
  %{
    identifier: issue.identifier,
    issue: issue,
    pid: nil,
    ref: nil,
    started_at: nil,
    last_codex_timestamp: nil,
    control: %{status: :deactivated}
  }
  ```
- Order matters: regular dispatch runs first (claiming `agent:in-progress` / `agent:rework` / `agent:merging` issues into `state.running`), then the revive pass runs over the human-review fetch result, skipping any that are now in `state.running`. This handles the race where an issue's label transitioned between fetch and synthetic-entry insertion.
- The synthetic entry surfaces through the existing `running_changed` broadcast → AgentList → renders 🏁. U4's synthetic 100 progress seed populates the bar.
- The synthetic entry is NOT terminated by `reconcile_stalled_running_issues/1` because the existing `is_integer(elapsed_ms)` guard at line 675 passes nil-timestamp entries (verified in U2's deferred-to-implementation note).
- Reactivation from the synthetic entry works the same as from a U2-created entry (`reactivate_issue/2` doesn't care whether the entry was created by deactivation or by boot revival).
- Boot revival only runs on `initial_dispatch_cycle: true`. Post-boot, `human-review` issues only appear via U2's live-transition path. Documented as a known asymmetry (see Risks).

**Patterns to follow:**
- The existing `initial_dispatch_cycle` gating (line 925) — single-pass behavior on startup only.
- `fetch_candidate_issues/1` (client.ex line ~18) — query shape, error handling, label normalization.
- The existing pattern for inserting running entries from issue lists.

**Test scenarios:**
- Happy path: orchestrator boots; GitHub poll returns 1 issue labelled `agent:in-progress` and 1 labelled `agent:human-review`. The in-progress issue dispatches a turn (existing behavior). The human-review issue gets a synthetic running entry with `control.status: :deactivated`. Covers AE5.
- Edge case: an issue is already in `state.running` (e.g., from the regular dispatch's claim — race scenario). Boot revival does NOT overwrite the existing entry.
- Edge case: an issue's label is `agent:human-review` but the issue is closed on GitHub. Skip — only open issues get synthetic entries.
- Edge case: 5 issues labelled `agent:human-review`, all open. All 5 get synthetic entries. None hold slots.
- Edge case: GitHub fetcher returns an empty list for `agent:human-review`. Boot pass no-ops.
- Edge case: post-boot, a 6th `human-review` issue appears on the next poll (initial_dispatch_cycle is now false). Not revived; row only appears via U2's live-transition path. Acceptable; documented in Risks.
- Edge case: race — between the two fetches, an issue's label transitions from `agent:in-progress` to `agent:human-review`. Regular dispatch claims it as in-progress. Revive pass sees it in `state.running` and skips. The issue runs a turn, and the next poll will trigger U2's live transition on the now-human-review state.
- Integration: after boot revival, U5's reactivation triggers (chat input, PR review comment, pause/resume, label flip) all work on the synthetic entry.

**Verification:**
- New tests green. Live verification: with a ticket in `agent:human-review` from a previous run, restart aiur (`scripts/aiur stop all && aiur --test`). The 🏁 row should appear immediately on boot before any new agent dispatches.

---

## System-Wide Impact

- **Interaction graph:** Orchestrator's `reconcile_issue_state/4` and `reconcile_stalled_running_issues/1` learn a new `:deactivated` branch (U2). `active_running_count/1` (U3) gains an additional exclusion. AgentList's `running_changed` handler (U4) splits its filter, seeds a synthetic progress sample, and tracks `rewarming_ids`. The chat-input GenServer call (U5) detects `:deactivated` and routes; the pause-key call returns `:already_inactive`. A new firehose subscriber for `ticket.+.pr.review_comment` joins the orchestrator's startup. Initial dispatch cycle (U6) gains a parallel revival pass after a new GitHub fetch.
- **Error propagation:** `reactivate_issue/2` failures (dispatch raises) leave the entry as `:deactivated` — the operator sees the row didn't change glyph, can retry. No new error class.
- **State lifecycle risks:** Boot revival (U6) might create a synthetic entry for an issue that's been merged on GitHub but the label hasn't transitioned yet (race). Mitigation: the next poll's `reconcile_issue_state/4` will see the terminal state and `terminate_running_issue(cleanup_workspace=true)` removes the synthetic entry. Short-lived inconsistency, no data loss. The publisher tracked-set drop in U2 prevents late events from the killed task from corrupting the post-deactivation bar reading.
- **API surface parity:** `aiur attach <issue>` (if any external CLI command exists) should work on `:deactivated` entries the same as on `:working` entries — the row is in the AgentList, the chat pane re-warms on demand. No new CLI surface needed.
- **Integration coverage:** End-to-end via `aiur --test`. The U1 prompt fix + the full U2-U6 stack are exercised by a single complexity:1 ticket flow (AE1). U5's PR-comment trigger requires a hand-driven GitHub comment to verify in live testing.
- **Unchanged invariants:** `tracker.active_states` config stays as `todo, in-progress, rework, merging`. Terminal-state cleanup (`agent:done`, `agent:cancelled`) still removes the entry entirely. Pause/resume on `:working ↔ :paused` is unchanged. The renderer's `progress_cell/2` green-at-100 path (commit `e6eb167`) is unchanged. The bar width (10) and per-turn cap (2) shipped in `dcfee74` / `7f0dba9` are unchanged. `:done` work_state semantics (turn-completion broadcast reason in `Aiur.AgentPubSub`, `turn_done_reason` in `agent_runner`, terminal-state rendering in `summary_emoji/2`) are unchanged — `:deactivated` is additive.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Synthetic boot-revived entry has no `started_at`, so the AGE column shows `?s/0t` — operator confused | U4 renders `—/—` for boot-revived (`started_at: nil`) `:deactivated` rows; live-deactivated rows (with real `started_at`) show actual elapsed time. |
| PR review-comment subscriber misses comments on the PR body itself (which GitHub emits as `IssueCommentEvent`, not `PullRequestReviewCommentEvent`) | Per origin scope, this is intentional — issue-body / PR-body comments are NOT reactivation triggers. Re-evaluate after first operator feedback if PR-body comments turn out to be the more common signal. |
| Operator opens chat pane on a `:deactivated` row, sees ⏳ "Warming up…" indefinitely because opencode pane re-warm fails | U4's `rewarming_ids` tracks the cold-start state; if `attach_state` never arrives (opencode crashed), the visual remains ⏳ and the operator can re-press Enter or try chat input which will fail with a clear error. No silent stuck state. |
| `reactivate_issue/2` fires for many simultaneous PR review comments (operator triages 10 PRs in a row), spamming the dispatch queue | The first reactivation flips `:deactivated → :working`; subsequent comments see `:working` and no-op silently. `max_concurrent_agents` is the natural backpressure on dispatch. |
| `:deactivated → :working` reactivation loses some state (last attention chips, latest event) | U4 keeps the per-id maps in compaction via `visible_ids`. The running entry retains its `issue` reference. The next agent turn picks up from the workpad just like a continuation. Test scenario in U5 covers a chat-input reactivation. |
| Post-boot, a new `agent:human-review` issue appears on the next poll but is NOT revived (one-shot guard) | Acceptable; the next poll's `reconcile_issue_state/4` will fire U2's live-transition path the moment the orchestrator becomes aware of the issue, BUT only if the issue was previously in `state.running` (e.g., an active label transitioned). A `human-review` label that appears between two polls on an issue that was never `:working` in this process is genuinely lost until next restart. Operators can flip the label to `agent:in-progress` and back to recover. |
| AgentList accumulates many 🏁 rows over time, cluttering the list (no dismiss affordance) | Out of scope per origin's "Deferred for later" — time-out for 🏁 rows. Operators can flip the GitHub label to `agent:cancelled` to dismiss. Revisit if row count > 20 becomes a routine complaint. |
| Boot revival's synthetic entries pile up after long aiur uptime | Same as above — no per-session dismiss. The synthetic entries are cheap (small map per entry, no pid, no pane), so memory cost is bounded by the number of open `agent:human-review` issues on GitHub. |
| Adding `:deactivated` atom introduces a new pattern to maintain across renderer / orchestrator / events | Bounded: one new `state_emoji/1` clause, one new `paused_running_entry?`-style predicate, one new `emoji_sort_key/1` clause. Each is single-line. The `:done` semantic for turn completion is unchanged, so existing consumers of `:done` don't need an audit. |
| `put_running_control_status/3` helper's narrow guard could silently drop a `:deactivated` write if a future contributor uses it | U2 mutates the entry directly via `put_in/3` and includes a comment at the helper documenting why it cannot be used for `:deactivated`. The narrow guard is preserved because `put_running_control_status/3` is for pause/resume control messages, which `:deactivated` is not. |
| `pr.review_comment` topic only fires on per-line review comments, not on top-level PR comments — the brainstorm may have intended both | Documented in Scope Boundaries. The origin's "PR comment is the canonical signal" is ambiguous on which firehose topic. If operator feedback shows the wrong topic was picked, swap `pr.review_comment` for `issue.commented` (filtered to issues with an open PR) in a follow-up — same wiring, different topic match. |

---

## Documentation / Operational Notes

- `elixir/prompts/shared-agent-instructions.md` is the only operator-visible doc change in the prompt layer (U1).
- `elixir/local-workflows/WORKFLOW.aiur.local.md` requires NO change — `tracker.active_states` stays as `todo, in-progress, rework, merging`.
- `Aiur.AgentEvents.state_emoji/1` moduledoc updated in U2 to document `:deactivated` as a distinct lifecycle phase ("agent has stopped working for this iteration; ticket lives at 100% awaiting reactivation").
- The `Agents: codex (N/M)` counter behavior change (`N` drops when a row enters `:deactivated`) is operator-facing; mention in the U3 commit message so operators can grok the new behavior on first sight.
- The help screen's 🏁 legend updates from "agent fully finished" to "awaiting human review — space or chat to reactivate" (U4). Existing keybind hint for `space` still says "pause/resume selected agent" — on a 🏁 row this means "reactivate", which the legend makes clear.
- Manual test loop: `aiur --test` (the single-ticket sandbox shipped in `ba319a2`) exercises U1+U2+U3+U4+U5 in one flow. U6 requires a manual restart after the row is already `:deactivated`.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-28-aiur-deactivated-state-requirements.md](../brainstorms/2026-05-28-aiur-deactivated-state-requirements.md)
- **Predecessor plan (companion):** [docs/plans/2026-05-27-002-feat-agent-progress-emits-plan.md](2026-05-27-002-feat-agent-progress-emits-plan.md) — U1/U2/U3 shipped. R6 in this plan is the prompt-side gap that surfaced via the live test on issue #140 / PR #141.
- **Predecessor brainstorm:** [docs/brainstorms/2026-05-27-aiur-progress-event-emits-requirements.md](../brainstorms/2026-05-27-aiur-progress-event-emits-requirements.md) — why the 🏁 visual matters in the first place.
- **Live-test trace:** Issue #140 → PR #141 — the run that surfaced both the row-disappears bug and the missing 100% emit on complexity:1 paths.
- **Relevant code:**
  - `elixir/lib/aiur/orchestrator.ex` — `reconcile_issue_state/4` (552), `terminate_running_issue/3` (620), `active_running_count/1` (1602), `paused_running_entry?/1` (1621), `put_running_control_status/3` (~2569), `resume_issue/2` (2443), `handle_call({:send_operator_message, …})` (2077), `handle_call({:pause_agent, …})` (~2095), `refresh_tracked_set/1` (~173), `refresh_running_issue_state/2` (610).
  - `elixir/lib/aiur/agent_list/app.ex` — `active_ids` filter (486-492), per-id compaction (502-512), `record_progress_sample/2` (726), `emoji_sort_key/1` (1011), `paused_summary?/1` (910).
  - `elixir/lib/aiur/agent_events.ex` — `state_emoji/1` (172).
  - `elixir/lib/aiur/agent_list/renderer.ex` — `summary_emoji/2` (~779), `phase_placeholder/3` (~705), `age_string/1` (~881), `help_body_rows/1` (~228), `progress_cell/2` (already greens at 100).
  - `elixir/lib/aiur/events/github_firehose.ex` — `PullRequestReviewCommentEvent` (188 → topic line 203).
  - `elixir/lib/aiur/events/publisher.ex` — `bot_self_loop?/1` (~198), `tracked?/1` (~86).
  - `elixir/lib/aiur/github/client.ex` — `fetch_candidate_issues/1` (~18); U6 adds a sibling for `agent:human-review`.
  - `elixir/prompts/shared-agent-instructions.md` — `Progress emits` section.
- **Document-review pass:** 6 reviewer personas (ce-coherence, ce-feasibility, ce-product-lens, ce-design-lens, ce-scope-guardian, ce-adversarial-document). P0 fix incorporated: U6 fetch path explicit. P1 fixes incorporated: issue.commented dropped from U5; `put_running_control_status` guard documented + bypass; `:deactivated` atom introduced (vs reusing `:done`); `refresh_running_issue_state` routes through `reactivate_issue/2`. P2 fixes incorporated: explicit sort bucket, agents_with_content compaction, help screen legend, AGE placeholder, `rewarming_ids` transient visual, publisher tracked-set drop, `pending_reactivation` flag removed in favor of immediate `:working` transition. The race "percent=100 vs label" is documented with label as orchestrator-side source of truth.
- **Related code shipped this iteration:**
  - `dcfee74` Teach progress emits in shared prompt
  - `7f0dba9` Cap bare-progress emits per turn
  - `e6eb167` Widen bar to 10 and green at 100%
  - `ba319a2` Split --test into single and --test3
  - `22b116d` Make --clear blanket only when explicit
