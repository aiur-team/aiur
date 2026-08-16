---
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
date: 2026-08-15
---

# Stream Deck Agent Logs View - Plan

## Goal Capsule

**Objective.** Rebuild the Stream Deck logs surface so it reads like a chat window over the
ticket's shared event bus: one key per real event, an unmistakable selection, an opencode-shaped
transcript with real diffs, and a LIVE key that means "where the agent is right now".

**Product authority.** The operator, via the numbered defect list captured below. Every numbered
item is a requirement, not a suggestion.

**Open blockers.** None. Three root causes were established before design and are recorded here.

## Root Causes Established Before Design

### R1 — Only one event key ever appears

Two independent defects stack.

1. `Aiur.IssueLog` persisted `nil` as the **string** `"nil"`. `json_safe/1` had a catch-all
   `when is_atom(value) -> Atom.to_string(value)` clause, and `nil` is an atom in Elixir, so every
   turn-less transcript entry was written with `"turn_id":"nil"`. `AiurWeb.StreamdeckLogs`
   groups entries with `chunk_by(turn_id || {:entry, index})`; `"nil"` is truthy, so the fallback
   never fired and all 50 entries collapsed into **one** chunk — one event key, whose label is the
   newest entry's body and whose badge is the newest entry's role. A `role: command` entry maps to
   badge `EMIT`, which is precisely the observed `EMIT` / `cd …` key that rewrote itself on every
   relay flush.
2. Even with that fixed, the source is wrong. `AgentEventFeed.list/2` reads
   `IssueLog.read_tail/2`, i.e. the per-agent **provider transcript** (`*.agent_events.jsonl`) —
   individual user/assistant/tool/command messages. The shared event bus lives in a different
   file: `Aiur.Events.Publisher` fans out `ticket.<id>.…` topics and `IssueLog.record_event/3`
   persists them to `*.events.log`, read back by `IssueLog.event_history/2`. The logs surface was
   never looking at the bus at all.

### R2 — Progress bar flickers 0 → 70 → 0 on the device

`Aiur.Orchestrator.StatusReport.progress_percent/2` discards a retained reading and substitutes
integer `0` whenever the TicketActivity observation is not `:fresh`. The staleness window is 60s
and agents do not re-emit progress every minute, so each reading goes stale about a minute after
it lands. `TicketActivity.Projection` deliberately *retains* the percent and only annotates
freshness; only this consumer throws it away, which is why the dashboard stays steady while the
deck oscillates. A second, fleet-wide variant: `activity_by_identity/0` returns `%{}` on a 100 ms
snapshot timeout, zeroing every agent at once.

### R3 — What opencode actually renders

Verified against `github.com/anomalyco/opencode` (the Go/Bubbletea TUI was deleted in Nov 2025;
the current TUI is SolidJS on `@opentui/core`). The visual grammar, in the order it matters:

- **Assistant prose** — no border, no gutter, no fill. `paddingLeft: 3` on the page background,
  `markdownText` `#eeeeee`. No `ASSISTANT:` label anywhere.
- **Tool calls** — one-line rows with a two-column *glyph* gutter, Title Case tool names, args as
  `[k=v, k=v]`. Glyphs: `$` bash, `→` read, `←` edit/write, `✱` glob/grep, `⚙` generic. The row
  goes `textMuted` `#808080` once complete; failures go `error` `#e06c75`.
- **Tools with output** — a panel-filled block, `backgroundPanel` `#141414`, title in `textMuted`.
- **Bash** — no distinct colour. The `$` glyph is the entire differentiator; the command renders
  as `$ <command>` in `text`.
- **Diffs** — unified below 120 columns, full-row background fills (`diffAddedBg` `#20303b`,
  `diffRemovedBg` `#37222c`), sign glyphs in the brighter highlight colours
  (`#b8db87` / `#e26a75`), line numbers always on. No `+N −M` counts on the edit itself.
- **User turns** — the one element with a *visible* coloured `┃` left bar plus panel fill.
- **Identity is carried by layout, not labels.** That is the finding that governs this rebuild.

Not verified, and therefore not imitated: the exact glyphs `@opentui/core`'s `<diff>` element uses
for hunk headers and split-view separators (that package is not vendored in the opencode repo).

## Product Contract

### P1 — Event keys come from the shared event bus

One key per event in `IssueLog.event_history/2`: `:emit` / `:self` for events this ticket
published, `:consumed` for events delivered to it, `:emit_alert` for operator-facing alerts.
Direction comes from the marker *kind*, which is what the kind records; the *topic* supplies the
human label (`ticket.401.pr.merged` → "PR merged"). Deriving direction from the topic instead
would make the same `pr.merged` read as EMIT when published and CONSUME when received — the badge
would then describe the subject rather than the direction, which is the one thing it is for.

### P2 — An origin event always exists

The first key is always an origin anchor, even for a ticket that has published nothing. It owns
every transcript entry that precedes the first bus event, so no transcript row is orphaned and the
scroll always has a defined left edge.

### P3 — Chat ordering

Oldest at the far left, newest at the far right, for both the key row and the transcript. Entering
logs opens scrolled fully right. This inverts the previous newest-first flattening.

### P4 — Selection is unmistakable

Exactly one of {LIVE, one event key} is active at any moment. Pressing an event key activates it
and deactivates LIVE; LIVE reverses it. The active key is marked by a full-bleed accent plate, a
selection rail, and an inverted badge chip — not by a subtle gradient shift.

### P5 — The LIVE key is an agent key

Progress bar, ticket id, lane icon and provider mark, exactly as a root-level agent key, with the
title slot replaced by a centred `LIVE`. Bright green plate while live is the active view; the
agent-key treatment otherwise.

### P6 — Transcript styling follows R3

Assistant prose unlabelled and bright; tool rows with a glyph gutter, Title Case name and
bracketed args, muted once complete; commands as `$ …` on a panel fill; user turns with a visible
coloured bar.

### P7 — Real diffs

The bottom panel renders actual unified-diff lines with full-row fills and sign glyphs, not a
one-line `path +N -M` summary. The feed carries a bounded window of real hunk lines.

### P8 — Live typing

A completed string arriving for the newest row is animated in character by character, fast, so the
surface reads as the agent typing. Emulation is explicitly accepted.

### P9 — Progress has three states

`fresh`, `stale` (retained percent, rendered as not-current), `unknown` (no percent). Unknown must
not look like a real 0%. A known 0% paints a visible minimum stub; unknown paints a dashed track
and no stub.

## Out of Scope, and why

- **Rendering diffs with syntax highlighting.** The strip is five rows of ~16px on an 800×100
  panel; per-token colouring is not legible at that size and would carry a lexer for no gain.
- **Split-view diffs.** opencode itself only splits above 120 columns; the strip is far below that,
  so unified is the faithful choice, not a compromise.

## Success Criteria

- A ticket with N bus events shows N+1 keys (origin + N), not one.
- Selection is identifiable from across a desk.
- A ticket progressing genuinely shows a bar that does not return to zero between emissions.
- Demo mode exercises: multiple distinct events, the origin event, both selection states, live
  typing, real diffs, the styled transcript, and both stale and unknown progress.
