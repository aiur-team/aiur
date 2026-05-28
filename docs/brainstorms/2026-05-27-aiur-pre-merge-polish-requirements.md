---
title: Pre-merge polish for aiur/22-events-foundation
status: ready-for-planning
created: 2026-05-27
branch: aiur/22-events-foundation
pr: 98
---

# Pre-merge polish for events foundation branch

## Problem frame

Branch `aiur/22-events-foundation` (PR #98) is functionally green: events foundation, agent tools, chat-pane parity, and live-stream marker bridge all work. Manual testing surfaced five polish items that affect the operator's first-30-seconds experience of opening a chat pane and reading the agent list. The merge bar is "operator can run `aiur --test`, see three agents become ready, open each chat pane, and watch real work happen without confusing artifacts." These items close the remaining gaps to that bar.

Other plan units (`U16-U20`, `U22`, `U23`, the dashboard events panel) are deferred to triage task #57 — they're real work but not required for this merge.

## Users and value

**Users:** operators driving multi-agent runs via the aiur TUI.

**Value of each item:**
- Knowing at a glance whether an agent is "ready to actually show content" vs "pane painted but empty" without opening every pane to check
- Color-dimmed command/tool blockquotes so the eye finds agent prose first
- A timed completion estimate that does NOT require the operator to babysit progress turn by turn
- A clean `aiur --test` reset so each test cycle starts truly fresh
- Diff hunks for edits instead of one-line "edit foo.ex" summaries — the operator wants to see what the agent changed without leaving the TUI

## Acceptance examples

### R1. Opencode theme override (dim blockquote text)

- **R1.1** Aiur ships a theme JSON at a path opencode discovers (TBD in planning: `~/.config/opencode/themes/` global vs project-local `.opencode/themes/`).
- **R1.2** Theme overrides `markdownBlockQuote` to a low-luminance color paired with the dark theme variants (and matching light if applicable).
- **R1.3** On `aiur --test` (or first run), aiur ensures the active theme is the aiur-shipped one — either via surgical merge into `~/.local/state/opencode/kv.json`'s `theme` key (preserving every other key) or via the opencode TUI command (planning decides which is safe).
- **AE1.1** Boot aiur, attach a chat pane, observe a `> $ command` line — the command text reads visibly dimmer than the agent's prose on the same screen.
- **AE1.2** A user with no prior opencode theme set sees the aiur theme active. A user with an existing custom theme is NOT silently overridden (planning decides the safety check).
- **AE1.3** No fork of opencode required; everything lives in aiur.

### R2. Progress + ETA columns in the agent list

- **R2.1** Agents emit `ticket.<id>.agent.progress` events with payload `%{percent: 0..100, label: optional}` on a WORKFLOW-configurable cadence (`events.progress_report_interval_seconds`, default suggested at planning).
- **R2.2** The agent list renders a new column with an ASCII progress bar (e.g. `[████░░░░] 50%`) reflecting the latest progress event per identifier.
- **R2.3** A separate ETA column renders a ticking countdown computed PROGRAMMATICALLY by the orchestrator (not the agent) from the last two samples' derivative. ETA decrements each render tick between samples and snaps to a fresh estimate when a new progress event arrives.
- **R2.4** Agent's responsibility ends at emitting `%{percent, label}`. The orchestrator/renderer owns the ProgressTracker (samples + derivative + ETA projection + bounded history).
- **R2.5** Stale samples (>N seconds since last update) freeze the ETA at `—` rather than ticking down forever. N is configurable in WORKFLOW.
- **AE2.1** Agent emits progress = 25% at t=0, 50% at t=30s. ETA cell shows roughly `2:00` (a 25% gain over 30 s projects 50% / 25 percent-per-30s = 60 s remaining). At t=45 s with no new sample, ETA reads `~45s`, decrementing each tick.
- **AE2.2** Agent never emits progress → bar empty, ETA shows `—`.
- **AE2.3** Agent emits 60% then 30% (non-monotonic — agent revised down) → new derivative computed from the two samples; bar shows 30%; ETA recomputed.

### R3. Workpad-comment cleanup in `aiur --test`

- **R3.1** `aiur --test` deletes (or edits-to-tombstone) any comment on each sandbox ticket whose body matches the agent workpad header (`## Agent Workpad`).
- **R3.2** After reset, opening the issue in GitHub shows NO workpad comment on tickets 99/100/101.
- **R3.3** The first agent run after `aiur --test` doesn't reference "prior workpad" or "existing workpad" in its first transcript message.
- **AE3.1** Manual `aiur --test` → `gh issue view 99 --json comments --jq 'map(.body) | map(select(startswith("## Agent Workpad"))) | length'` returns `0`.
- **AE3.2** Open chat pane on issue 99, read the agent's first agent-role line — it should be planning fresh work, not reconciling against prior workpad state.
- **Decision:** full delete, not tombstone. Tombstone preserves the visible artifact and the next agent still sees stale text. Audit is preserved in `IssueLog` + the `[event:emit]` log lines, which is the right home for it.

### R4. Edit-tool log: real diff view, not summary line

- **R4.1** When the agent invokes the `edit` tool (modifying a file), the chat pane renders the actual diff hunks (with red/green coloring) the way native opencode does — NOT a one-line `✏️ edit /path/to/file.ex (+1 more)` summary.
- **R4.2** Rendering uses opencode's NATIVE tool-result rendering (the same path that paints diff hunks today for direct opencode usage). Aiur does NOT recreate a markdown approximation.
- **R4.3** If native opencode rendering requires a structured tool-call payload, the bridge synthesizes/forwards that payload from the agent's edit tool result.
- **R4.4** If routing through opencode's native path turns out to be infeasible in the planning phase, fall back to a structured markdown diff (e.g. fenced ```diff blocks per file) — but only as a last resort, and capture that as an explicit decision.
- **AE4.1** Agent edits `event_flow_demo.ex` adding a function. Chat pane shows the file path, `+` lines for the new function body, and `-` lines for any removed code, colored as opencode normally colors them.
- **AE4.2** Multi-file edit shows each file's hunks distinctly (file header + hunks), in the same shape native opencode renders.
- **Open question (resolve in planning):** is the edit-tool result delivered to opencode as a generic assistant message we'd have to format, or does opencode emit a dedicated `tool_call` part that carries before/after content opencode already knows how to render? Planning needs to inspect opencode's existing tool-render path and decide whether we synthesize that payload from our bridge.

### R5. `❗` attention emoji + `Latest` column (U21 from events plan)

- **R5.1** State column expands to two emoji slots: existing status emoji (🟢/🟡/⏸️/🔴/🏁/⚫/⏳/🔘/⚪) **plus** a reserved slot that renders `❗` when any `attention.*` is open on the ticket and renders blank (reserved space, no jitter) when no attention is open. Multiple open attentions render `❗N` where N is the count.
- **R5.2** New `Latest` column on the far right of the agent list (existing columns + order unchanged). Cell shows the most recent event message for that ticket — message only, no topic prefix.
- **R5.3** `agent_summary` map gains `latest_event: %{topic: String.t(), message: String.t(), timestamp: DateTime.t()} | nil`. The existing `alert_count` field is dropped (replaced by the `❗N` slot derived from open attentions, which is a separate signal).
- **R5.4** A new global PubSub topic carries summary broadcasts the agent list subscribes to (e.g. `agents:events_summary` with `{:agent_event_summary, identifier, latest_event}`).
- **R5.5** Pressing `Enter` on a row with `❗` open expands an inline detail block: list of `<slug> · <message> · <relative_time>` per open attention. Pressing `Enter` again collapses.
- **AE5.1** Agent #100 emits `ticket.100.agent.attention.scope-question` with message "OK to namespace under Foo.Bar?". Agent list row for #100 immediately shows `🟢 ❗`. Latest column shows the truncated message.
- **AE5.2** Operator presses `Enter` on row #100 → detail block appears under the row: `scope-question · OK to namespace under Foo.Bar? · 12s ago`.
- **AE5.3** Operator presses `Enter` again → detail block collapses.
- **AE5.4** Agent #100 has 0 open attentions → State column shows `🟢 ` (status + reserved blank), Latest column shows truncated most-recent event or empty.
- **AE5.5** Layout doesn't jitter when attention state flips (reserved space is always allocated).

## Scope boundaries

### In scope

- Theme JSON shipped from aiur, theme activation logic, dim blockquote color (R1)
- New progress event topic, agent tool to emit progress, ProgressTracker GenServer/ETS, two new columns (R2)
- `gh api` comment delete in `test_reset.ex` (R3)
- Native diff rendering for edit tool — research-then-build, fallback explicitly captured (R4)
- `latest_event` + `❗` slot + Latest column + Enter-to-expand detail block (R5)

### Deferred to follow-up (triage task #57)

- `Aiur.Events.Inbox` (U16) — per-agent event-to-queue router
- Mid-turn checkpoint drain (U17) — urgent-allowlist matcher
- Turn-boundary digest builder (U18)
- IssueLog event taxonomy completion (U19)
- SessionWriter `:event_digest` handler (U20)
- Shared agent prompt six reflex rules (U22)
- `.claude/skills/aiur/` + 5 reference docs (U23)
- Dashboard events panel (separate plan `2026-05-24-003`)
- Auto-subscribe on `aiur_declare_blocker` + relationship metadata (existing task #45)

### Outside this product's identity

- Forking opencode for rendering changes (R1, R4)
- Modifying the agent's strategic reasoning behavior — agents only emit data; the orchestrator owns derivations like ETA (R2)
- Replacing GitHub as the workpad surface (R3) — workpad-via-comment stays the contract; we just clean it up

## Dependencies / Assumptions

- **R1 assumption:** opencode 1.15.x's theme discovery (verified via binary scan + theme.json schema fetch). Future opencode versions may change theme storage; if they do, R1 ages out gracefully — the worst case is the override silently stops applying.
- **R2 assumption:** an agent that emits progress is doing so honestly (rough percentage estimate, not a fake "I'm at 50%" boast). The shared agent instructions should add a one-liner asking agents to revise downward when they realize a task is bigger.
- **R3 assumption:** the workpad comment ALWAYS starts with `## Agent Workpad`. If the agent prompt ever changes the header, the cleanup regex needs a paired update — planning should add this to test coverage.
- **R4 assumption:** opencode 1.15.x exposes a tool-result rendering path that's reachable from our bridge. If planning research finds this is gated to opencode's internal tools only, fallback to structured markdown.
- **R5 dependency:** `SubscriptionStore` (U6 — built) for the `open_attentions` source of truth. The `❗N` count comes from `SubscriptionStore.snapshot(identifier).open_attentions`.

## Non-regression constraints from prior work

These properties must continue to hold after this batch lands:

- Agents work without opencode attached (no chat pane open = no codex blockage)
- `aiur --test` end-to-end runtime stays under ~60s of overhead (the 30s settle-poll + the launcher overhead + test reset, NOT the codex turn time)
- Chat pane shows agent text within the codex first-message latency floor (~20s) after the operator opens a pane — no regressions to the 23s E2E we measured
- The label-race fix in `test_reset.reset_labels_command_args/1` stays — agent:todo never gets stripped by --test
- The fire-and-forget marker fan-out in `AgentRunner.post_aiur_turn_markers/4` stays — codex turns must not block on marker posts
- All three agents must show ⚪ (pane painted AND content emitted), not just 🔘 (pane painted but empty), within the 23s window when content actually exists

## Open questions for planning

1. **R1 — global vs project-local theme + activation mechanism.** Project-local feels heavier (one theme file per workspace = 3 × in sandbox); global is one-time but touches user state. Planning picks one based on safety vs ergonomics. The activation question (kv.json merge vs CLI vs TUI palette) is paired.
2. **R2 — `aiur_emit_progress` tool vs extending an existing event.** New tool is cleanest; reusing `emit_event` keeps the surface narrow. Planning picks one.
3. **R2 — bar character set.** Block-element progress (▏▎▍▌▋▊▉█) gives sub-character resolution; simple `█░` is more portable. Planning picks based on what opencode's renderer + the operator's terminal will reliably show.
4. **R4 — opencode's tool-result rendering path.** Planning has to inspect opencode 1.15.10's bundled JS to find the render seam. If it's a tool-call part with structured `before/after` fields, we can synthesize. If it's purely text we have to format, we go fallback.
5. **R5 — `❗N` rendering when N is double-digit.** `❗10` is 4 visual columns; might break alignment. Planning picks: cap at `❗9+` or accept variable width.

## Success criteria

- Operator's first 30 seconds after `aiur --test` shows: 3 agents transitioning ⏳ → 🔘 → ⚪ (existing fix), commands rendered in dim blockquote (R1), progress + ETA columns updating live (R2), edit-tool output showing real diff hunks (R4), Latest column live (R5), no stale workpad references in any agent's first message (R3)
- All five items are committed individually so each can be reverted independently if a problem surfaces post-merge
- `mix test` stays at 0 failures (excluding flakes from concurrent BEAM runs in test_helper)
