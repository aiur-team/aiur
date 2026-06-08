---
date: 2026-05-31
topic: website-opencode-pane-v2-staged-narrative
supersedes-beat-of: docs/brainstorms/2026-05-31-website-opencode-chat-pane-requirements.md
---

# Website "Take the Wheel" — opencode Pane v2 (Staged Steering Narrative)

## Why a v2

The take-the-wheel beat shipped (PR #242) as a short, whole-line, box-drawing
opencode pane whose decision *caused* #321's downstream `#321 → #324` unblock.
After watching it live, the operator wants a more faithful, more cinematic
rework. This document captures only the **deltas** from the shipped
requirements (`docs/brainstorms/2026-05-31-website-opencode-chat-pane-requirements.md`)
— everything not restated here still holds (single-`<pre>` grid, 1Hz repaint,
braille spinner, ShopWave dashboard demo conventions, deterministic loop, clean
reset).

The v2 reframes the loop to tell **two distinct stories as two separate
occurrences**, in order:

1. **Human-in-the-loop steering (first):** the cursor walks to a stuck ticket
   (#321), opens a pre-warmed opencode session, reads the agent's surfaced
   decision, the human types a reply, and the agent acknowledges. This beat does
   *not* resolve the ticket and does *not* cause a downstream unblock — it shows
   what taking the wheel looks like.
2. **Autonomous unblock (after):** a *separate* occurrence between **two other
   agents** (not the human-driven #321) demonstrates the event bus — one agent
   publishes a "ready" event, a second blocked agent ingests it and unblocks, no
   human involved.

The two stories are deliberately **decoupled** so each reads cleanly: "a human
can jump in and steer one agent" *and*, separately, "agents coordinate and
unblock each other on their own."

---

## Decisions (the deltas)

### D1. Two separate occurrences — human steering first, then an autonomous unblock between two other agents

The loop tells both stories, but as **distinct, sequential occurrences** rather
than one causal chain.

**Occurrence 1 — human steering on #321 (first):** #321 surfaces a decision and,
after the operator answers "lets brainstorm options," the agent replies it will
go think — #321 stays **unresolved** (the human engaged it; the agent did not
finish). This beat causes **no** downstream unblock.

**Occurrence 2 — autonomous unblock between two other agents (after):** a
distinct pair, **not #321**, shows the event bus: one agent publishes a "ready"
event, a second blocked agent ingests it and leaves `blocked`. Recommended:
**reuse the existing `#318 → #319` chain** (codex finishes the OAuth callback →
sonnet's login-form ticket auto-unblocks) — two agents, no human — and sequence
it to play **after** the human beat closes.

Consequences for the data model (resolved in planning, noted here for trace):
- **Sequence the human #321 beat before the `#318 → #319` auto-unblock** in loop
  time (#318→#319 currently fires at ~t=8–14, before the beat; re-time so the
  human beat comes first and the autonomous unblock follows).
- **Drop the `#321 → #324` causal tie:** remove #321's `t=26 "schema migrated to
  uuid pks"` publish and #324's `t=46 "← #321: schema ready, unblocking"`
  receive. #321 holds a `decide` / "awaiting options" state through the beat
  instead of resuming at t=26. #324 stays blocked on #321 for the loop
  (coherent: #321 is mid-decision) — it is *not* the auto-unblock example.
- The shipped assert check `#321.publish.t < #324.receive.t` is removed; add a
  check that the human beat opens before the `#318 → #319` receive fires.

This reverses shipped R5/AE4 (decision-causes-unblock): the human beat and the
autonomous unblock are now independent demonstrations, not a single chain.

### D2. Faithful opencode chrome — background blocks, not box-drawing lines

Recreate opencode's visual language as closely as the monospace `<pre>` grid
allows. Replace the box-drawing chrome (`┃` rail on every line, `┌┐└┘` input
box) with **background-colored regions**, matching the reference screenshots:

- **Assistant prose:** plain text, no rail, no background.
- **Command / tool lines (`$ …`, `→ …`):** a short **accent gutter bar** on the
  left only — this is the *only* place a gutter marker appears. Dim tool-result
  text, accent/ok command text.
- **User message (posted):** a **background-tinted block** spanning the pane
  width, the operator's text inside it. This is how opencode renders the human's
  own turns.
- **Status chip:** `▣ Build · issue-321` in accent; braille spinner while the
  agent is working.
- **Alert line:** `❗ Alert sent.` (replaces the shipped `👍` acknowledgement
  glyph). The `❗` must be width-pinned so the grid does not drift.
- **Input box:** a **filled background field** with an accent left bar (not a
  drawn rectangle), showing the typed text + a blinking cursor, with the
  `Build · issue-321 its-everdred/shopwave` label beneath. No `┌┐└┘`.
- **No footer / help text** in either pane at any resolution (already removed
  from the dashboard; remove the opencode `esc interrupt …` footer too). Frees
  vertical space; the keys were an unimportant detail.

### D3. Typewriter is allowed — scoped to the operator's input only

The shipped R7 / handoff-spec §10 rule "no typewriter, lines appear whole" is
**intentionally relaxed for one element only:** the operator typing into the
input box, character-by-character at **semi-random but consistent** speeds
(~80–140ms/char), because a human literally typing is real, expected motion —
not fake letter-by-letter rendering of model output.

Everything else still appears **whole** on the 1Hz repaint: the static
transcript history, the `❗ Alert sent.` line, the pre-loaded A/B/C question, the
posted user message (appears whole the instant Enter "posts" it), and the
agent's reply. The dashboard pane is unchanged. The typing animation is a
**deterministic function of loopSec** (sub-second resolution is fine at the
existing 100ms tick), so the loop stays reproducible and reset-clean.

### D4. Cursor walks the agent list to open and to close

Before the pane opens, the selection cursor **descends the agent-list rows
one-by-one** until it lands on #321, then the pane opens. After the agent
replies and a beat passes, the pane closes and the cursor **walks back up** to
the top row. The left dashboard pane **keeps updating its event log** the whole
time (ambient fleet motion continues during the steering beat). Descent/ascent
pacing (~1 row per ~0.4–0.5s) is a planning detail; it must read as deliberate,
not instant.

### D5. Staged interactive sequence (the new narrative)

One continuous beat, in order:

1. **Cursor descent** down the agent list to #321 (stuck, `decide` + spinner).
2. **Pane opens** beside the abbreviated dashboard.
3. **Static history** (whole lines): the agent's recent work — reading the
   schema, making an edit, hitting a snag — ending in a statement that it is
   **blocked on an important user-facing decision**.
4. **`❗ Alert sent.`** appears at the bottom of the transcript, and the agent's
   question is **already loaded** (whole): *"This approach is more complex than
   the ticket first assumed. How should I proceed? A. Brainstorm a different
   approach  B. Continue anyway  C. Stop and await instructions."* (copy
   refined in planning — concise + believable.)
5. **Operator types** `lets brainstorm options` into the input box,
   character-by-character (D3), cursor blinking.
6. **Enter posts** the message: the input box clears and the text appears as a
   new **user-message background block** at the bottom of the transcript.
7. **Realistic pause**, then the agent replies (whole line): *"OK. Let me get
   back to you with some options."*
8. **Another pause**, then the **pane closes** and the cursor **walks back up**
   to the top of the list (D4) while the left pane's log keeps updating.

### D6. Reduced-motion static frame

Freeze on the most informative steady state: pane open, the posted user message
block (`lets brainstorm options`) and the agent's reply both visible, input box
empty, cursor static (no blink). Avoids freezing mid-type or on a half-open
pane.

### D7. Responsive (already shipped in this session)

Stack the panes vertically only on a **truly narrow portrait** viewport;
medium-width and landscape viewports keep the dashboard and opencode pane
side-by-side. Wide screens also pin the dashboard log to 3 lines. (Shipped:
`Wide res: 3 logs, drop footers`.)

---

## Unchanged from the shipped requirements

- Single-`<pre>`, container-query font, ≤96-col budget, column-wise join.
- 1Hz content repaint; braille spinner ~10fps the only ambient sub-second motion
  (now joined by the operator's input typing, per D3).
- ShopWave dashboard demo conventions (phase emoji, AGENT column, `10/15`).
- Driven ticket is **#321** (UUID PK migration); `decide` phase + stalled cue.
- Clean loop reset: all beat state derived from `loopSec`, nothing persists
  across the wrap.
- No real interactivity / backend / model output — deterministic script.

---

## Success Criteria

- A first-time viewer watching one loop sees, unmistakably, a human walking to a
  stuck agent, reading its surfaced decision, typing a reply, and the agent
  acknowledging — "take the wheel" now has a vivid, faithful referent.
- The pane reads as the **real opencode UI** (background message blocks, accent
  gutter on commands, filled input field, `❗`/chip), not box-drawing chrome.
- The only motion that breaks "whole-line repaint" is the operator's own typing;
  everything else still snaps in whole, so the CLI illusion holds.
- The loop still resets identically and never overflows the grid at any tier.

---

## Outstanding Questions (for planning)

- Exact A/B/C question copy and the static-history transcript lines (D5 steps
  3–4) — draft + refine while rendering.
- Exact beat timeline constants within the 90s loop (descent start, open,
  type window, send, reply, close, ascent end) **and the re-sequencing** so the
  human #321 beat plays before the `#318 → #319` autonomous unblock (D1) — must
  keep the rest of the fleet storyline coherent.
- Confirm the auto-unblock pair: reuse `#318 → #319` (recommended) or pick
  another non-#321 pair. #324 stays blocked all loop (recommended) since #321
  never delivers.
- How background-block regions are rendered within the `<pre>` (full-row
  background spans) and which palette tokens they use, without breaking the
  column-width / emoji-width math.
- Golden snapshot + assert script updates (drop the `#321.publish < #324.receive`
  check; add a "human beat opens before `#318 → #319` receive" check; re-capture
  non-beat goldens).

---

## Next Steps

→ /ce-plan to update `docs/plans/2026-05-31-001-feat-website-opencode-pane-plan.md`
(or write a v2 plan) with the implementation units for D1–D6. Work pushes
directly to `main` per the operator's standing instruction for website fixes.
