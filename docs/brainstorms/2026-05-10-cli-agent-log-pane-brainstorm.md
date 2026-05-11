---
date: 2026-05-10
topic: CLI agent log pane
branch: symphony/agent-log-pane
status: ready-for-planning
---

# CLI Agent Log Pane

## What We're Building

When the operator presses `space` or `enter` on the foreground `agents` CLI dashboard, the currently-selected running agent expands into a log pane below the agent list. The pane shows the same chat-style log as the web dashboard's per-agent log modal (built from `logs/agent.md` / `logs/agent.ndjson`). The "Backoff queue" section is hidden while the pane is open. A placeholder single-line input box sits under the log pane to reserve space for the eventual chat/interrupt feature. `left` arrow or `esc` closes the pane.

Out of scope: actually sending messages to the agent or interrupting it. Only the placeholder is built now.

## Why This Approach

The dashboard already owns the renderer, selection state, and per-tick refresh. Adding a "view mode" to the dashboard's state machine reuses that pipeline:

- `TerminalInput` already dispatches keypresses → dashboard casts. Extend the keymap, no new processes.
- The dashboard's tick already produces a fresh snapshot for re-render. The log pane reads the agent's log on the same tick, so live updates are free.
- The chat-style parser lives in `dashboard_live.ex`'s private helpers today. Extracting them to `SymphonyElixir.AgentLogView` lets both the LiveView modal and the CLI pane share one source of truth.

Considered alternatives:

- **Separate `AgentLogPane` GenServer** — clean separation of concerns, but the log pane has no independent lifecycle or state worth isolating; it's a render mode of the dashboard. Over-engineered for this scope.
- **Duplicate the LiveView parser** — faster to ship, but invites drift between the web modal and CLI pane every time the log format evolves.
- **Inline a smaller chat parser** — trades visual parity for less code. User chose parity.

## Key Decisions

### Behavior

| Concern | Decision |
|---|---|
| Open trigger | Both `space` and `enter` |
| Close trigger | `left` arrow and `esc` |
| Log content | Chat-style with system/user/assistant roles; reuses LiveView's `agent_log_modal/1` + `compact_log_messages/1` parsing |
| Source file | `logs/agent.ndjson` (same as LiveView modal) |
| Live updates | Re-render on dashboard tick (~1s); pane reflects new events without manual refresh |
| Layout | Status header + agent list at top; log pane fills remaining terminal height; single-line input placeholder pinned to bottom |
| Backoff queue | Hidden while pane is open |
| `j`/`k`/arrows while pane open | Switch the selected agent AND reload the pane with that agent's log |
| Scrollback | Supported via `PgUp`/`PgDn` |
| Auto-scroll | Stick to bottom unless user has scrolled up; `PgDn`-to-end resumes auto-scroll |
| Selected agent finishes while pane open | Pane stays open showing final log; left/esc still closes |
| Input row shape | Single-line bordered box with hint text (e.g. `│ > [send disabled — coming soon] │`) |
| Input row keys | None active yet; the box is purely visual placeholder |

### Architecture

| Concern | Decision |
|---|---|
| Where view-mode state lives | New field on `StatusDashboard` state (e.g., `view: :list \| {:log, issue_identifier, scroll_offset}`) |
| Casts for new keys | New `StatusDashboard` API: `open_log/1`, `close_log/1`, `scroll_log_up/1`, `scroll_log_down/1` |
| Chat parser location | Extract from `SymphonyElixirWeb.DashboardLive` private helpers into a new shared module `SymphonyElixir.AgentLogView` (or similar). LiveView modal calls into it; CLI pane calls into it |
| Snapshot pipeline | Existing dashboard snapshot remains the source of truth for the running/backoff lists; the log pane separately reads the selected agent's ndjson tail per tick |
| Tests | Snapshot tests for the new render modes (list vs log; backoff visible vs hidden; with/without scrollback offset); unit tests for the extracted `AgentLogView` (covering the cases currently exercised through LiveView tests) |

## Open Questions

None — all design questions have been resolved in the dialogue above. Implementation details (exact module names, snapshot fixture organization, scroll-offset clamping) belong in the plan, not here.

## Out of Scope

- Sending messages to the agent
- Interrupting / pausing an agent
- Cross-agent log search or filter
- Multi-agent split-pane view
- Resizing the pane manually
- Persisting the pane state across `agents` restarts
- macOS portability of `/proc/self/fd/0` (separate concern from PR #10)
