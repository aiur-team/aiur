# Stream Deck parity reference

The three files beside this one are the **verbatim** Stream Deck slice of the
Claude Design mock, extracted from `Aiur Dashboard.html` in the design project
`5e62b9a9-39c1-4ca2-9a76-6dff123a088c`. They are the parity target for
`/streamdeck` and for the downloadable Stream Deck package.

| file | source lines | what it is |
| --- | --- | --- |
| `streamdeck.design.css` | 410-618 | every `.sd-*` rule, verbatim |
| `streamdeck.design.html` | 1704-1723 | the panel markup (a shell; the surface is rendered by JS) |
| `streamdeck.design.js` | 3645-4307 | the behavioural contract |

Source artifact: 279,364 bytes, sha256
`cbcb26fe5fac22f898dadae414650018a80e89e56a45869030c6c9249d542c80`.

Do not edit these files to make an implementation match. They are the
specification. If the mock is wrong, change the mock in Claude Design and
re-extract.

## Why the JS is the spec

The panel markup is four empty containers: `#sd-keys`, `#sd-screen`,
`#sd-knobs`, and a brand header. Every pixel an operator sees is produced by
`sdRenderKeys`, `sdRenderCmdKeys`, `sdRenderLogKeys`, `sdBuildGridStrip`,
`sdBuildCmdStrip`, and `sdBuildLogStrip`. Reading the HTML alone tells you
almost nothing.

## The three modes

`sdMode` is one of `grid`, `cmd`, `logs`. The keys, the touch strip, and the
dial semantics all change with it. A parity implementation that models only the
grid has implemented roughly a third of the surface.

### grid

Eight keys, four columns by two rows. The agent at a slot is
`sdAgents[(sdColOff + col) * 2 + row]` — **column-major**, so paging moves
horizontally through columns, not through pages of eight.

`sdAgents` is not the raw fleet. It is filtered to the five buckets
(`running`, `alert`, `paused`, `stuck`, `queued`) and sorted by `SD_RANK`
(`alert` 0, `stuck` 1, `running` 2, `paused` 3, `queued` 4), with queued
agents further sorted so unblocked ones come first. Blocking is derived:
`sdReady` walks `blockedBy` and requires every upstream to be at `pct >= 100`
or `control === "Merged"`.

Each key carries: a line-art icon from the Build Order icon set, the provider
logo as an `<img>`, a priority star when `_prio`, the ticket number, the title,
and a footer. Queued keys get a status label plus an `Unblocked`/`Blocked` tag.
Every other state gets a status dot and a progress bar whose fill colour is
**hue-mapped**, not a fixed accent:

```js
const hue = (pct / 100 * 125).toFixed(0);
// background: hsl(<hue> 72% 50%)
```

0% is red, 100% is green, and everything between is interpolated. A fixed-colour
bar is not parity.

Key background is the state's `glow` gradient; the inner face is the state's
`face` gradient. Both come from `SD_ST`.

### cmd

Entered by clicking an agent key. The eight key slots become four commands and
four blanks:

| slot | command | toggles to |
| --- | --- | --- |
| 1 | Pause | Play, when `control === "Paused"` |
| 2 | Prioritize | Deprioritize, when `_prio` |
| 3 | Logs | — |
| 4 | Mic (hold, not click) | — |

Mic binds `pointerdown`/`pointerup`/`pointerleave`/`pointercancel` and holds a
`mic-live` class for the duration. It is not a click target.

### logs

Entered from the Logs command. The eight keys become a scrolling window over the
event list, starting at `sdEventIdx`. Event 0 renders as a distinct **LIVE** key
with a pulsing dot rather than as an event row; every other slot shows a
direction badge (`EMIT`/`CONSUME`/`INFO`/`AGENT`/`SYSTEM`, each with its own
colour from `SD_LOG_DIR`), the event text, and a relative timestamp.

Clicking an event key is the behaviour that matters most:

```js
sdSel = idx;
sdChatIdx = Math.min(sdEvStart[idx] || 0, sdChatMax());
```

`sdFlat` is the transcript flattened into one array — an `evhdr` entry followed
by that event's chat entries, newest event first — and `sdEvStart[i]` is where
event `i` begins in it. So clicking an event key **scrolls the touch strip to
that event's position in the transcript**. The strip is a two-row window into
`sdFlat` starting at `sdChatIdx`.

## Dials

Four dials. Each supports wheel, pointer drag (a 270° sweep spans the full
range, `delta / 2.7`), and arrow keys. A pointer-up with less than 8° of
accumulated movement is a **press**, not a drag.

| dial | turn | press |
| --- | --- | --- |
| A (0) | in `logs`, scrolls the transcript and re-selects the event under the cursor | `sdBack` — logs to cmd, cmd to grid |
| B (1) | free value | — |
| C (2) | free value | — |
| D (3) | in `grid`, pages columns; in `logs`, moves the event window | `sdCycleWindow` — next window, wrapping |

A press must not rotate the dial. Both `sdCycleWindow` and the event-key path
recompute `sdKnob3` from the new offset specifically to keep the visual dial in
sync without turning it.

## Touch strip

Four segments, and the strip is **mode-dependent**.

In `grid`: a SUMMARY segment (aiur logo, live/left counts, a Build mini-bar with
an ETA), one segment per provider (logo, a Session mini-bar with time remaining,
a Weekly mini-bar with a reset day), and the pager segment showing
`MORE AGENTS` with a dot per window.

In `cmd`: a single full-width page with the agent's icon, provider logo, number,
title, status, percentage, a hue-mapped bar, and a `BACK` hint under dial A. The
pager segment relabels to `CONTROLLING` with the agent's number.

In `logs`: the two-row transcript window plus hint labels under dials A and D.
Both hints carry directional arrows whose visibility reflects whether there is
anything further in that direction (`sdBackHint`, `sdEvHint`) — the arrows are
state, not decoration.

Provider segments are per-provider with **two** meters each (session and
weekly). A single combined percentage is not parity.

## What "functionally accurate" means here

The mock runs on generated data. Parity is not copying the fixtures — it is
that every value the mock derives from its fixture is derived from real fleet
state in the implementation:

- keys map to actually-dispatched agents, in the ranked order above
- the progress bar reflects real ticket progress, hue-mapped
- `Blocked`/`Unblocked` comes from real dependency state
- log keys are real events from the durable feed, and clicking one really does
  move the strip to that point in the real transcript
- provider segments read real session and weekly meter readings
- Pause really pauses, and the dashboard and `aiurdev status` agree afterwards
