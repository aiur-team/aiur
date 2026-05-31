---
date: 2026-05-31
topic: website-opencode-chat-pane-animation
---

# Website "Take the Wheel" — opencode Chat-Pane Animation

## Problem Frame

The marketing site (`website/`) runs a looping, text-only simulation of the Aiur agent dashboard — a fleet of agents working ShopWave tickets in parallel, with a live event log and the famous `#318 → #319` auto-unblock storyline. It sells the "fleet of autonomous agents coordinating via events" idea well.

But feature card #04, **"Take the Wheel"** — the human dropping into a pre-warmed opencode session in a tmux pane to drive a single ticket — is described in prose only and never shown. The dashboard sim demonstrates *autonomous* coordination; nothing demonstrates *human-in-the-loop* intervention. This adds an animated opencode chat pane that dramatizes taking the wheel, completing the visual story of how Aiur actually works.

The reference for the existing sim's behavior and fidelity rules is `elixir/docs/brainstorms/2026-05-30-aiur-terminal-simulation-handoff.md` (hereafter "the handoff spec"). This feature extends that sim; all of its fidelity rules (§10) and the two scripted unblock chains stay intact.

---

## Actors

- A1. **Operator** (the human): watches the fleet, selects a ticket, presses `enter` to take the wheel, types a decision into the opencode chat, then closes the pane.
- A2. **Driven agent** (opencode session for one ticket): surfaces a decision, acts on the operator's answer, makes a small edit, and resumes — publishing an event that the fleet reacts to.
- A3. **Fleet** (the existing dashboard sim): keeps running in the other pane; one downstream ticket auto-unblocks as a consequence of the driven agent's resumed work.

---

## Key Flows

- F1. **Take the wheel on a stuck ticket** (the scripted beat, within the ~90s loop)
  - **Trigger:** Scripted loop time reaches the "open" beat (~t=28s). The dashboard sim has been running solo since t=0.
  - **Actors:** A1, A2, A3
  - **Steps:**
    1. The dashboard's `▶` selection moves to the driven ticket, which has flipped to a *needs-decision* state and stalled (spinner + "needs a decision" LATEST text).
    2. The operator "presses enter": the terminal box splits — dashboard shrinks to the left pane, an opencode chat pane opens on the right (stacked vertically below the breakpoint).
    3. The opencode pane shows the agent's surfaced question, the operator's typed decision, a brief agent acknowledgement, one small tool action (e.g. updating the plan / a small edit), and a resume confirmation.
    4. The driven ticket leaves the needs-decision state, its progress resumes, and it publishes its "ready" event into the shared log.
    5. The pane closes (`q`); the terminal returns to the full-width dashboard.
    6. A downstream blocked ticket ingests the driven ticket's event and auto-unblocks — visible in the now-full-width dashboard before the loop resets.
  - **Outcome:** The viewer has seen a human make a judgment call that an agent acted on, which in turn unblocked another agent autonomously — human-in-the-loop and event-bus coordination shown back-to-back.
  - **Covered by:** R1, R2, R3, R4, R5, R6, R7, R8

---

## Requirements

**Layout & lifecycle**
- R1. The take-the-wheel beat is rendered as a **tmux-style split within the existing terminal box**: dashboard pane + opencode chat pane sharing one continuous scene (not a separate page section, not a full-screen swap on wide screens).
- R2. The split is a **timed beat inside the existing loop**, not persistent: dashboard-solo → split opens → session plays → pane closes → dashboard-solo, then loop reset. The full-width dashboard phases on either side must look identical to today's sim.
- R3. Opening and closing are motivated by the existing footer affordances: the `▶` selection moves to the driven row and "enter" opens; "q" closes. This reuses keys the footer already advertises.

**Session content (the story)**
- R4. The dramatized archetype is **"unblock / decide for a stuck agent"**: dialogue-driven, human-in-the-loop. Tool UI is present but minimal (at most one small edit/plan-update + a resume), so the decision is the focus.
- R5. The driven ticket must be one that **does not already auto-resolve** in the current script, so the human story and the event-bus stories stay distinct. Recommended: **#321 "Migrate users table to UUID PKs"** (see Key Decisions) — its existing downstream `#321 → #324` unblock then becomes a *consequence* of the operator's decision.
- R6. The driven ticket gains a brief **needs-decision state** before the operator opens it (a stalled row surfacing a question), and leaves that state once the decision is given.

**Fidelity**
- R7. The opencode pane obeys the same fidelity rules as the dashboard: **1Hz repaint, braille spinner at ~10fps, no other animation**. Chat lines appear **whole on a repaint — no typewriter / letter-by-letter effect**, no fades or easing. (Honors handoff spec §4, §10.)
- R8. The opencode pane reproduces the **real opencode session chrome** shown in the operator's reference screenshots (see "Reference: real opencode pane" below), not a generic chat bubble. Its elements, top to bottom:
  - A scrolling **transcript** of: shell-command lines prefixed `$ …`; dim `→ tool result` / `→ ToolSearch` lines; and brighter **assistant prose** lines (e.g. "Function verified — returns 42.").
  - A left **gutter rail** (`┃` / `│`) marking the active turn.
  - A **status chip** line `▣ Build · issue-<N>` (filled-square glyph, accent color), optionally with an elapsed `· NNNms`.
  - A bottom **input box**: a short box with a colored (blue) left border and a `Build · issue-<N> <project>` label — this is where the operator's typed decision appears.
  - A **footer**: a braille progress meter (`⬝⬝⬝⬝⬝⬝⬝■`) on the left and `esc interrupt   tab agents   ctrl+p commands` keys.
  - It shares the existing aesthetic: same monospace grid, palette, and emoji-width handling.

**Responsive**
- R9. Reflow follows the operator's two reference shots:
  - **Wide (side-by-side):** dashboard pane on the left, opencode pane on the right. To make horizontal room, the **dashboard pane drops its LATEST column** (keeps ID, status, TITLE, PROGRESS, TIME) — exactly as the real UI does when split.
  - **Narrow (stacked):** the two panes **stack vertically** (dashboard on top — full width, so it *keeps* LATEST — opencode below), separated by a horizontal rule. A horizontal tmux split.
  - The box never overflows horizontally or squishes; it reflows by dropping/abbreviating columns as the dashboard already does.
- R10. The split must work at the sim's existing breakpoint tiers (wide / medium / narrow per handoff spec §8); the opencode pane truncates its own transcript lines with `…` rather than overflowing.

**Accessibility / loop integrity**
- R11. With `prefers-reduced-motion`, the feature follows the existing sim's reduced-motion behavior (the sim currently renders a representative static frame instead of animating); the split beat must resolve to a sensible static frame, not a broken half-open state.
- R12. The loop resets cleanly: at the boundary, the pane is closed and all driven-ticket state returns to its t=0 seed, identical to the dashboard's existing reset.

---

## Acceptance Examples

- AE1. **Covers R1, R2.** Given the loop is at t=10s, when the viewer looks at the terminal, then it shows only the full-width dashboard (no split). Given the loop is at t=45s, then the box is split with the opencode pane visible. Given the loop is at t=80s, then it is full-width dashboard again.
- AE2. **Covers R5, R6, R4.** Given the driven ticket is #321, when the beat opens, then #321 is shown in a needs-decision state with a surfaced question; when the operator's decision line appears, then #321 leaves the needs-decision state and its progress bar begins advancing again.
- AE3. **Covers R7.** Given the opencode session is playing, when a new chat line appears, then the entire line appears at once on a 1Hz repaint (no characters typing in one at a time), and the only sub-second motion anywhere is the braille spinner.
- AE4. **Covers F1 step 6.** Given the driven ticket (#321) has published its "schema ready" event, when the downstream ticket (#324) is next visible, then #324 has ingested the event and left its blocked state — demonstrating the decision's downstream effect.
- AE5. **Covers R9.** Given a narrow viewport during the beat, when the split is open, then the dashboard and opencode panes are stacked vertically and neither overflows horizontally.

---

## Success Criteria

- A first-time viewer who watches one loop can describe both ideas: "the agents coordinate on their own" *and* "a human can jump in and steer one." The "Take the Wheel" feature card now has a visible referent.
- The added pane is indistinguishable in aesthetic from the existing sim — same fonts, borders, palette, cadence — so it reads as one coherent CLI, not a bolted-on widget.
- A downstream implementer can build the beat from this doc without inventing the layout model, the loop timing structure, the driven-ticket choice, or the fidelity constraints. The exact chat copy is the only thing they may refine.

---

## Scope Boundaries

- No real interactivity: the footer keys remain decorative; the viewer cannot actually drive the session. (Consistent with the current sim.)
- No real opencode integration, no backend, no live model output — it is a deterministic scripted animation like the rest of the sim.
- Not full opencode-TUI fidelity: we show a believable, *minimal* slice (prompt, agent reply, one tool action, result), not opencode's complete chrome (model picker, token counts, multi-tab history, syntax-highlighted multi-file diffs).
- Does not change the dashboard's existing tickets, event timeline, or unblock chains beyond adding the brief needs-decision beat to the single driven ticket.
- Mobile does **not** skip the beat (we chose vertical stacking), but heavy opencode tool UI may be trimmed further at the narrowest tier if it does not fit.

---

## Key Decisions

- **Layout = tmux split, one scene** (vs. separate section or full-screen swap): most faithful to the real "take the wheel" experience, where opencode opens in a pane *beside* the dashboard. Rationale: the product's whole pitch is overseeing the fleet *while* steering one agent — seeing both at once is the point.
- **Timed beat (open → drive → close)** (vs. persistent split): preserves the dashboard's existing full-width composition for most of the loop and creates a before/after contrast that reads as a deliberate human action rather than ambient UI.
- **Story = decide/unblock** (vs. course-correct with diffs, or read-only Q&A): emphasizes human judgment, which is the distinct value of taking the wheel; keeps tool UI light so we don't have to render high-fidelity multi-file diffs.
- **Driven ticket = #321 "Migrate users to UUID PKs"** (recommended): a migration backfill is a believable, real judgment call ("online backfill vs. maintenance window"), and #321 already feeds the secondary `#321 → #324` auto-unblock — so the operator's decision visibly *causes* a downstream autonomous unblock, tying the two narratives together. The driven agent kind follows #321's existing kind in `simData.ts`.
- **No typewriter** (chat lines appear whole at 1Hz): the existing sim's fidelity checklist forbids letter-by-letter text; a chat that types would break the "real CLI repaint" illusion the rest of the sim maintains.

---

## Dependencies / Assumptions

- Builds directly on the existing `website/src/` sim modules (`dashboard.ts`, `simData.ts`, `terminal.ts`, `styles.css`). Verified present on `origin/main`, so this work branches off `main` independently of the npm/init feature branches.
- Assumes the existing breakpoint/reflow machinery in `dashboard.ts` (character-column-based) can be reused or extended for the split rather than rebuilt.
- Assumes a believable minimal opencode chat representation is acceptable for marketing purposes (we are not reproducing opencode's real TUI exactly). The repo's own notes on how opencode renders commands/tool-results/file-edits (`AGENTS.md`) can inform the styling but are not a fidelity contract here.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R1, R2][Technical] How to structure the split in the renderer: compose two independently-built bordered boxes joined column-wise into the single `<pre>`, vs. two side-by-side `<pre>` elements. Affects how vertical stacking (R9) is implemented.
- [Affects R6][Technical] How to represent the brief "needs-decision" ticket state in `simData.ts` — reuse `⏳`/blocked styling with new LATEST text, or add a distinct state/emoji. (Handoff spec §3.4 lists no dedicated "needs decision" emoji.)
- [Affects R4, R5] Exact opencode chat copy for the #321 session (the surfaced question, the operator's decision line, the agent acknowledgement, the resume line). Draft below; refine during planning/implementation.
- [Affects R2][Technical] Precise beat timestamps within the 90s loop (open ~t=28s, decision ~t=33s, #321 publishes ~t=40s, close ~t=45s, #324 unblocks ~t=50s) — must keep #321's publish before #324's existing unblock.
- [Affects R10][Needs validation] Whether the opencode pane fits legibly at the narrowest (≤79 col) tier when stacked, or whether its content needs an extra-aggressive trim there.

---

## Reference: real opencode pane (from operator screenshots, 2026-05-31)

The operator supplied two screenshots of the actual Aiur tmux split — wide (side-by-side) and tall (stacked) — as the fidelity target for the opencode pane. Salient details captured there:

- Transcript mixes `$ <shell command>` lines (commands can wrap across two rows), dim `→ tool result` and `→ ToolSearch` lines, and brighter assistant prose ("I'll proceed with the workflow… Let me move the issue to in-progress, verify the function, and open a fresh PR.", "Function verified — returns 42. Issue is in-progress.").
- A `▣ Build · issue-99` status chip recurs as the agent works; one instance showed `· 142ms`.
- Bottom input box has a blue left border and the label `Build · issue-99 Aiur`.
- Footer: braille progress meter (`■■■⬝⬝⬝⬝⬝`) + `esc interrupt   tab agents   ctrl+p commands`.
- In the wide shot the **dashboard pane has no LATEST column**; in the tall shot (dashboard full-width) LATEST is present — confirming R9's reflow.
- Note the real dashboard there is in single-kind mode (`Agents: claude (3/6)`, status *dots* 🟢/⚪, no AGENT word). The website sim deliberately stays in **ShopWave demo mode** (phase emoji 🛠️/🏁/⏳, AGENT column, `Agents: 10/15`). Keep the dashboard demo conventions; only the *opencode pane* mimics the real chrome above.

## Proposed opencode session script (draft — refine in planning)

Driven ticket: **#321 — Migrate users table to UUID PKs**. In the opencode pane, one whole line per ~1Hz repaint, in the real transcript style above:

```
  ┃ $ mix ecto.migrate --dry-run
  ┃ → tool result
  ┃ Dry-run done. Backfilling 2.1M users will lock the
  ┃ table ~40s on prod. How should I run the backfill?
  ▣ Build · issue-321

 ┌─────────────────────────────────────────────────┐
 │ › online backfill in batches, no lock            │   ← operator types here
 │ Build · issue-321 Aiur                           │
 └─────────────────────────────────────────────────┘

  ┃ 👍 switching to batched online backfill
  ┃ $ edit priv/repo/migrations/..._add_uuid.exs
  ┃ → tool result
  ┃ schema migrated to uuid pks — pushed
  ▣ Build · issue-321 · done
  ⬝⬝⬝⬝⬝⬝⬝■   esc interrupt    tab agents   ctrl+p commands
```

This keeps tool UI minimal (one dry-run, one edit, one result), foregrounds the operator's decision in the input box, and ends on the exact event text (`schema migrated to uuid pks`) that #324 already ingests in the current dashboard script — so the human decision visibly causes the downstream auto-unblock.

---

## Next Steps

-> /ce-plan for structured implementation planning (branch off `origin/main`; open as its own ticket/PR, separate from the npm/init stack).
