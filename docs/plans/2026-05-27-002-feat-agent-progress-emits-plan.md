---
title: "feat: Agent progress emits — 1/10 scale on phase boundaries"
type: feat
status: active
date: 2026-05-27
origin: docs/brainstorms/2026-05-27-aiur-progress-event-emits-requirements.md
---

# feat: Agent progress emits — 1/10 scale on phase boundaries

## Overview

The events foundation (PR #98) and the subscriptions/inbox/drain layer (PR #130) shipped the wire format and the renderer plumbing for per-agent progress: `Aiur.ProgressTracker` samples + ETA derivation, the `progress_by_id` map in `Aiur.AgentList.App`, the ASCII bar column in `Aiur.AgentList.Renderer`. What's missing is the agent-side emit — nothing today tells agents when to emit, at what granularity, or how to estimate honestly.

This plan wires that last mile with the cheapest possible token budget. Agents emit `%{percent}` at phase boundaries (start / end of `brainstorm` / `plan` / `work` / `review`) at 1/10 granularity (10, 20, …, 100). The terminal `percent: 100` lands on the same phase-end event the agent emits when it's about to stop working (typically `phase.review.end` after `gh pr ready` + label flip). The renderer turns the bar green whenever the most recent progress sample reads 100. One column scan tells the operator "how far is each agent".

---

## Problem Frame

Today the progress-bar column is dead pixels — every row shows `░░░░░░░░ ETA —` because no agent ever emits an `agent.progress` event. The brainstorm settled all the product questions; this plan is the implementation path.

Tightened constraints from the brainstorm:

- **Agent token cost is the hard constraint.** Every `emit_event` is a tool call → LLM round-trip. A 2-emit-per-turn cap and a phase-boundary-only cadence keep the lifetime budget around 8-15 emits per ticket.
- **Time-based percent, not output-based.** Agents are bad at "I've written X% of the code"; they're much better at "this whole thing including review and CI will take ~30 min". Percent reflects wall-clock progress through the agent's *full* timeline.
- **Cleanup-aware.** No fixed default magnitude for the post-code tail. A typo fix has near-zero tail; a refactor has hours. The agent calls it out in the `label` so the operator can see what's being budgeted.
- **Stop-work = 100% + green.** The agent emits `percent: 100` exactly once — as part of the phase-end event that signals end-of-work for this iteration (typically `phase.review.end` after `gh pr ready` and the label flip to `agent:human-review`). The renderer turns the bar green whenever the latest sample reads 100. The agent owns the transition because the agent is the only thing that knows it's actually done.

---

## Requirements Trace

- R1. Agents emit `ticket.<id>.agent.progress` with `%{percent, label}` on phase boundaries (start + end of brainstorm / plan / work / review). Granularity is units of 10: 10, 20, 30, …, 100.
- R2. Mid-phase emits are allowed but rare: only when the agent's estimate has shifted ≥ 15 percentage points OR ≥ 50% of the remaining-time estimate.
- R3. Per-turn cap: max 2 progress emits per agent turn. Beyond that, the `emit_event` tool returns an error so the agent learns the constraint.
- R4. The `label` field names the agent's cleanup-aware tail (e.g., `"work: code typed, expect ~2 review rounds + CI"`).
- R5. The agent emits `percent: 100` exactly once — paired with the phase-end event that signals end-of-work (typically `phase.review.end` after `gh pr ready` and the issue label flip to `agent:human-review`). The renderer tints the bar green whenever the latest progress sample is `percent: 100`.
- R6. The progress bar width is 10 characters wide (currently 8 in `elixir/lib/aiur/agent_list/renderer.ex` at `@progress_bar_width`).

**Origin acceptance examples:** AE1 (per-phase emit + non-zero start when prior phases ran), AE2 (`%{percent, label}` carried through the existing ProgressTracker path), AE3 (mid-phase corrections on CI failures or scope shifts), AE4 (label format readable + ≤80 chars).

---

## Scope Boundaries

- Time-interval cadence (every N seconds) — replaced by the estimate-shift threshold (R2) to keep token cost bounded.
- Output-based percent (lines-of-code, tests-passing, etc.) — replaced by time-based (R1).
- Orchestrator-derived progress (reading git commits or plan checkboxes to infer percent) — the agent has the best information about its own remaining timeline; redundant inference adds carrying cost without value.
- Dashboard panel rendering of progress samples — deferred to the dashboard ticket (Ticket C from the events foundation plan).
- Alerts.yaml entries for progress events — silent by design.
- New event vocabulary — reuses the existing `agent.progress` topic and `Aiur.ProgressTracker` infrastructure shipped on PR #130.
- Persisted estimate across orchestrator restart — the agent recomputes from wall-clock awareness (continuation count, workpad timestamps) on every turn.
- Workpad reference for the agent's initial estimate — agents already have wall-clock awareness; persisting in the `## Agent Workpad` comment is fluff and a token tax.

---

## Context & Research

### Relevant Code and Patterns

- `elixir/lib/aiur/progress_tracker.ex` — `bar/2`, `format_eta/1`, `estimate/2`, `record/3`. Already shipped + exercised by `progress_by_id` in the agent list.
- `elixir/lib/aiur/agent_list/renderer.ex` — `@progress_bar_width 8` constant + the `ProgressTracker.bar(pct, @progress_bar_width)` rendering at lines 643/646. Two updates needed: width → 10, plus a state-aware tint when work_state ∈ `{:human_review, :merging}`.
- `elixir/lib/aiur/agent_list/app.ex` — `progress_by_id` state + the `running_changed`/`status_changed` PubSub handlers that update each row's `work_state`. The state is already available at render time; no new plumbing needed for the green-on-handoff transition.
- `elixir/lib/aiur/codex/dynamic_tool.ex` — `emit_event` tool definition + vocabulary allowlist. The per-turn cap goes here, modeled on the existing `custom.<slug>` cap (already present from the foundation brainstorm).
- `elixir/prompts/shared-agent-instructions.md` — the shared prompt that every workflow-rendered agent receives. The 1/10 scale, cleanup-aware tail rule, and phase-boundary cadence live here.
- `elixir/lib/aiur/agent_events.ex` — `state_emoji/1` etc., used by the renderer to pick the per-row state glyph. Useful as a precedent for state-aware rendering, but the green-fill override is a renderer concern, not an `AgentEvents` concern.

### Institutional Learnings

- **PR #130's coalesce-at-drain pattern**: granularity preserved upstream (one queue item per publish), folding happens only at the drain boundary. Same shape applies if we ever want to fold multiple progress samples — but with a 2-emit-per-turn cap and phase-boundary cadence, the volume doesn't warrant coalescing.
- **The `custom.*` per-turn cap precedent** in `Aiur.Codex.DynamicTool` is the exact pattern for R3. Reuse the cap mechanism rather than building parallel infrastructure.

---

## Key Technical Decisions

- **No conversion layer for the 1/10 scale.** The agent emits the existing `%{percent}` payload directly with values in `[10, 20, 30, …, 100]`. The prompt teaches the granularity; no code-side mapping. The agent-list bar's pixel resolution at width 10 maps each 10% step to exactly one filled cell, so 1-of-10 in the agent's head equals one cell on screen.
- **100% is agent-emitted on stop-work.** The agent emits `percent: 100` as part of the final phase-end event before it stops working (typically `phase.review.end` after `gh pr ready` and the label flip). The agent owns the transition because the agent has authoritative knowledge of "I'm done for this iteration"; a label-poll race or renderer-side heuristic would lag and lie. The renderer simply reads the latest sample and tints green at 100.
- **Percent-aware tint, not state-aware.** The renderer reads the existing `progress_by_id` map (already passed to `render/1`). When the most recent percent for a row is 100, the bar gets the green ANSI wrap. No new payload field, no `work_state` lookup, no new event.
- **Per-turn cap enforced in `emit_event`, not in the orchestrator.** Each `Aiur.Codex.DynamicTool.execute(emit_event, …)` invocation in the same codex turn counts against the cap; the 3rd progress emit returns an error response so the agent's prompt teaches itself the constraint. This mirrors the existing `custom.*` cap and keeps the enforcement local.
- **Cleanup-aware honesty is a prompt rule, not a validator.** No code attempts to check whether the agent's `label` actually mentions cleanup. Validation would burn tokens and add policing tone to the prompt. The brainstorm's R2.2 teaches the rule; the operator sees the label and decides whether the agent budgeted honestly.

---

## Open Questions

### Resolved During Planning

- **Storage of the agent's initial estimate?** Agent recomputes each turn from wall-clock awareness (continuation count, workpad timestamp). No orchestrator-side persistence beyond what ProgressTracker already does.
- **Phase weighting?** Agent emits freely with prompt guidance ("review + CI usually account for ⅓+ of the total"). No hard-coded percentages.
- **Workpad reference?** No — agents recompute, persistence is unnecessary.
- **What signal carries percent: 100?** Agent-emitted. Paired with the same phase-end event that signals end-of-work for this iteration (typically `phase.review.end`, fired right after `gh pr ready` and the label flip to `agent:human-review`). Renderer is dumb — it greens whenever percent reads 100, regardless of which event delivered it.

### Deferred to Implementation

- **Exact ANSI sequence for the green tint.** Existing `Aiur.Opencode.Style` and `Aiur.AgentList.Renderer` ANSI conventions decide. Likely a wrap of `bar/2`'s output with the same green-ish ANSI used elsewhere; implementer picks during U3.
- **Test setup for the `emit_event` cap.** `elixir/test/aiur/codex/` has no `dynamic_tool_test.exs` today. The implementer either adds one or reuses an existing test seam (e.g., test the cap as a unit via the `execute_emit_event/2` helper directly).
- **Cap counter scope.** Two reasonable choices: (a) reset on each codex turn boundary (per the brainstorm's wording — "per turn"), (b) reset on every full agent turn (`run_turn` from `agent_runner.ex`). Lean (a) but defer the exact reset hook until the implementer sees the codex turn/transcript wiring.

---

## Implementation Units

- [ ] U1. **Teach the 1/10 scale + cleanup-aware tail in the shared prompt**

**Goal:** Update `elixir/prompts/shared-agent-instructions.md` so every agent invocation sees the new rules. Cover: (a) emit `agent.progress` with `percent ∈ {10, 20, …, 100}` on every phase boundary, (b) the percent reflects wall-clock progress through the FULL ticket lifetime including review + CI tail, (c) the `label` field must name the tail being budgeted, (d) emit `percent: 100` exactly once — paired with the phase-end event that signals end-of-work (typically `phase.review.end` after `gh pr ready` and the label flip to `agent:human-review`). Never emit 100 earlier; the bar turning green is the operator's signal that the agent is done for this iteration. (e) mid-phase corrections allowed only when estimate shifts ≥15pp or ≥50% of remaining time, capped at 2 emits per turn.

**Requirements:** R1, R2, R4

**Dependencies:** None

**Files:**
- Modify: `elixir/prompts/shared-agent-instructions.md`

**Approach:**
- Add a new section between the "Events between turns" cross-ticket events block and the "Event vocabulary" allowlist. Title: "Progress emits — 1-of-10 estimate at phase boundaries".
- Three subsections: when to emit, how to estimate, how to label.
- Concrete example showing a phase.work.start → progress(percent: 50, label: "work: typing function_a, ~2 review rounds budgeted") pair so the agent has a worked exemplar.

**Patterns to follow:**
- The existing "Cross-ticket events" section in the same file is the right shape and depth: rule + rationale + one worked example.

**Test scenarios:**
- Happy path: render a sample agent prompt and confirm the new section appears verbatim with the correct allowlist of `percent` values.
- Test expectation: none for the prompt content itself beyond a smoke render check — prompt prose is documentation, not behavioral code.

**Verification:**
- Manual: render the workflow prompt via `Aiur.PromptBuilder.render/2` for a sandbox ticket and read the progress section against the brainstorm's R1-R4.

---

- [ ] U2. **Close the bare-`progress` wiring gap + cap `progress` emits at 2 per codex turn in `emit_event`**

**Goal:** Two changes in `elixir/lib/aiur/codex/dynamic_tool.ex`. First, close a pre-existing wiring gap: the agent-list renderer reads topic `ticket.<id>.agent.progress` (bare), but the current `@agent_event_exact` allowlist only accepts `progress.<slug>` — so today nothing can ever populate `progress_by_id`. Add bare `progress` to the exact-match allowlist. Second, when the agent fires `emit_event(name: "progress", …)`, increment a per-turn counter; on the 3rd attempt in the same turn return an error response so the agent's prompt teaches the limit.

**Requirements:** R3, R5 (the renderer side of R5 belongs in U3, but bare-`progress` acceptance is the upstream half)

**Dependencies:** U1 (the prompt has to teach the rule and the bare name before the tool starts enforcing the cap).

**Files:**
- Modify: `elixir/lib/aiur/codex/dynamic_tool.ex`
- Test: `elixir/test/aiur/codex/dynamic_tool_test.exs` (create if absent)

**Approach:**
- Add `"progress"` to `@agent_event_exact`. Update the schema description string (`"Vocabulary tag. One of: progress.<slug>, …"`) and the error-payload examples to include the bare `progress` topic with `%{percent, label}` payload.
- Cap mechanism: mirror the existing `custom.<slug>` per-turn cap pattern. Same counter mechanism, scoped to the literal name `progress`.
- Counter reset: at codex turn boundary. Reuse whatever turn-id-scoped storage the existing cap uses (`Process` dictionary keyed by turn id, ETS table keyed by `(identifier, turn_id)`, etc. — implementer matches the local pattern).
- Error response shape: same `{:error, %{message: …, reason: :progress_cap_exceeded}}` as the `custom.*` cap, so the agent sees a consistent shape.

**Patterns to follow:**
- Existing `custom.*` cap in `elixir/lib/aiur/codex/dynamic_tool.ex` — copy-paste-equivalent for the `progress` name.
- Existing `@agent_event_exact` list (`"blocked"`, `"unblocked"`, `"attention.resolved"`, `"pause.request"`) — same shape.

**Test scenarios:**
- Happy path: `emit_event(name: "progress", payload: %{percent: 20, label: "…"})` is accepted by `validate_emit_event_name/1`.
- Happy path: 2 sequential `emit_event(name: "progress", …)` calls in the same turn both succeed.
- Edge case: 3rd `emit_event(name: "progress", …)` call returns `{:error, %{reason: :progress_cap_exceeded}}` and the underlying event is NOT published.
- Edge case: the cap resets on a new turn — 2 emits in turn-1 + 2 emits in turn-2 all succeed.
- Edge case: progress and custom share NO budget — 5 custom emits + 2 progress emits in one turn all succeed.
- Edge case: `progress.brainstorm-end` (slug form, existing vocab) still works and counts against neither cap.

**Verification:**
- Unit test covers the cap interaction and the new allowlist entry; lint + test gates clean; the live behavior is visible in the manual test (progress events emitted at phase boundaries land in the agent list, mid-phase oversteps log an error in the per-issue log).

---

- [ ] U3. **Renderer: bar width 10, green tint at `percent: 100`**

**Goal:** Bump `@progress_bar_width` from 8 to 10 so each 10% step maps to exactly one cell. Tint the bar green when the row's most recent `progress_by_id` value reads 100. No `work_state` lookup — purely percent-driven, because the agent is the authoritative signal for "done".

**Requirements:** R5, R6

**Dependencies:** None — purely a renderer change, no upstream prereq.

**Files:**
- Modify: `elixir/lib/aiur/agent_list/renderer.ex`

**Approach:**
- Change `@progress_bar_width 8` to `@progress_bar_width 10`.
- In the bar-rendering branch (around lines 643/646), add a percent-aware override: when the row's progress percent equals 100, wrap the `ProgressTracker.bar(100, @progress_bar_width)` output in a green ANSI sequence (reuse whatever green wrap `Aiur.Opencode.Style` or local helpers already define; add `green/1` if missing).
- Adjust column-width math if the bar's display width affects the row layout — the renderer's `compute_layout/2` may need a width tweak (+2 cells for the bar column).

**Patterns to follow:**
- Existing `progress_by_id` lookup in the same render path — same map access, just key on the percent value for the green branch.
- ANSI color wrapping: existing `Aiur.Opencode.Style.dim/1` is the right precedent (one-function color helper). Add `green/1` if it doesn't exist.

**Test scenarios:**
- Happy path: render a row with `progress_by_id: %{"99" => 50}` → bar shows 5 filled cells out of 10, no green.
- Happy path: render a row with `progress_by_id: %{"99" => 100}` → bar shows 10 filled cells, all green.
- Edge case: no progress entry → bar shows 0 filled cells (existing behavior, no green).
- Edge case: render at narrow terminal width where the progress column gets shrunk — the green tint still applies (color, not width).
- Integration: re-run existing renderer tests against the new width to confirm column-width math didn't regress.

**Verification:**
- Existing renderer test suite passes; one new test asserts the green tint fires when percent equals 100; visual inspection during the manual 3-ticket sandbox confirms the bar greens at the moment the agent emits its final 100% sample.

---

## System-Wide Impact

- **Interaction graph:** Agent → `Aiur.Codex.DynamicTool.execute(emit_event, …)` (per-turn cap enforcement) → existing `Aiur.Events.Publisher` → existing `Aiur.ProgressTracker` sample storage → `Aiur.AgentList.App` `progress_by_id` → `Aiur.AgentList.Renderer` bar. The green tint runs entirely inside the renderer reading `progress_by_id`; no new event path, no `work_state` lookup.
- **Error propagation:** Cap exceedance is a typed `{:error, %{reason: :progress_cap_exceeded}}` returned to the agent. Doesn't crash anything. The agent sees the error and adjusts (this is part of the teaching loop the cap exists to drive).
- **State lifecycle risks:** Per-turn cap counter must reset cleanly on turn boundaries. If reset is missed, the cap effectively becomes "2 emits per agent lifetime" — false-positive cap rejections on every turn after the first. Unit test covers the reset path.
- **API surface parity:** No public API change. The `emit_event` tool shape, `agent.progress` topic, and `%{percent, label}` payload all already exist. Only the renderer column width and the prompt rules change.
- **Integration coverage:** The 3-ticket sandbox manual test exercises the full chain — agent emits, ProgressTracker samples, renderer paints, label-flip greens. Worth running once after U3 lands.
- **Unchanged invariants:** `Aiur.ProgressTracker` semantics (sample retention, ETA projection, stale-sample handling) stay exactly as shipped on PR #130. The existing `custom.*` cap and other emit-event vocabulary stay unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Agents over-emit progress events anyway, eating token budget | The cap returns errors, which the agent reads and corrects. Plus the prompt teaches the rule explicitly. Both lines of defense exist. |
| Agents under-emit (skip phase boundaries entirely) | The prompt makes the rule a phase-boundary requirement, not an opt-in. The dev loop already pairs phase emits with `emit_alert("phase.X.start")` — adding a sibling progress emit is a copy-paste. |
| Bar width change from 8 → 10 breaks horizontal layout on narrow terminals | Renderer's `compute_layout/2` already shrinks columns adaptively. Add 2 chars of slack to the layout math if needed; existing test covers the narrow-terminal case. |
| Green ANSI doesn't render on the user's terminal (e.g., monochrome SSH session) | The bar still fills to 100% even without color — the fill alone communicates "done". Color is bonus. |
| Cap counter leak: a long-running agent never resets, eventually rejects every emit | Tied to codex turn-id reset. Unit test must cover the multi-turn case so this regression is caught. |
| Agent skips the 100% emit (forgets, errors out, hits a crash mid-turn) | The bar stays at the last sample (e.g., 90%) and never greens — operator sees the agent didn't formally close out. Matches reality; no false positive. The prompt rule pairs the 100 emit with `phase.review.end`, which is already a required closing step. |
| Agent emits 100 prematurely (before PR is actually ready) | The prompt teaches that 100 means "I'm done for this iteration." A premature 100 is operator-visible as "bar greened but no PR appeared" — caught by the same eyeballs that catch any other lying agent. Validator would burn tokens without catching the same case. |

---

## Documentation / Operational Notes

- `elixir/prompts/shared-agent-instructions.md` is the documentation. No separate doc updates.
- WORKFLOW.aiur.local.md needs no changes — no new config knobs in this plan (the brainstorm's `events.progress_report_interval_seconds` is explicitly dropped in favor of estimate-shift triggers).
- Manual test loop: `aiur --test` against the 3-ticket sandbox, watch the progress column fill + green over the run. Cross-check against per-issue log `[event:self]` lines for `agent.progress` topic to confirm cadence is 8-15 per ticket lifetime.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-27-aiur-progress-event-emits-requirements.md](../brainstorms/2026-05-27-aiur-progress-event-emits-requirements.md)
- **Related plan (predecessor):** [docs/plans/2026-05-27-001-feat-subscriptions-and-inbox-plan.md](2026-05-27-001-feat-subscriptions-and-inbox-plan.md) (PR #130 merged; this plan reuses the ProgressTracker + renderer plumbing shipped there)
- **Related issue:** [#68 Replace status color circles with phase-specific emojis](https://github.com/its-everdred/aiur/issues/68) — complementary, not blocking. Both consume `phase.*` events; this plan handles the bar/ETA columns, #68 handles the state-column emojis.
- **Related code:**
  - `elixir/lib/aiur/progress_tracker.ex`
  - `elixir/lib/aiur/agent_list/renderer.ex`
  - `elixir/lib/aiur/agent_list/app.ex`
  - `elixir/lib/aiur/codex/dynamic_tool.ex`
  - `elixir/prompts/shared-agent-instructions.md`
