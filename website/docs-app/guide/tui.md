# TUI

The terminal UI (TUI) is the live agent-list board plus opencode chat panes opened into individual agent sessions.

![The aiur TUI: the agent-list board and a chat pane opened into a live agent session](/images/tui/aiur-tui.gif)

The TUI is built on tmux with opencode serving the chat panes, so an Executor can chat with an agent directly in the same terminal where the fleet is visible — send a message, watch the agent act on it, and interrupt it, without leaving the board.

## The agent-list board

The board shows one row per ticket. A row carries runtime, turn count, backend, pinned model, work state, and pause reason. A state circle prefixes each row so the operator can read the fleet at a glance:

| Glyph | Meaning |
| --- | --- |
| ⏳ | warming up — pane not yet ready |
| 🧠 | brainstorming |
| 📋 | planning |
| 🔨 | implementing |
| 🔍 | reviewing |
| 🟢 | working — pane open now, no active phase |
| ⏸️ | agent paused |
| 🔴 | agent in error state |
| 🏁 | awaiting human review — space or chat to reactivate |
| ⚫ | agent waiting (queued, idle, or label only) |

Rows re-sort live: running agents bubble to the top, so the board always leads with the work that is actually moving.

## Keys

| Key | Action |
| --- | --- |
| `↑` / `k` | select previous |
| `↓` / `j` | select next |
| `enter` | open the selected agent's conversation pane |
| `shift+enter` / `O` | open in a new pane |
| `space` | pause / resume the selected agent |
| `←` / `→` | lower / raise the concurrency cap |
| `a` | attach to the selected agent |
| `r` | toggle remote control for the selected agent |
| `v` | toggle pane layout orientation (horizontal ↔ vertical) |
| `?` | toggle the help overlay |
| `q` | quit the agent list |

Press `?` in the board for the on-screen keybind and state-circle help.

## Chat panes

Pressing `enter` on a running agent opens its chat pane beside the board. From there an Executor types directly into the live session — messages queue while the agent is mid-turn and are delivered after the current turn finishes. The opencode runtime and the agent transcript remain the source of truth; the pane is a live window onto it.

Tickets cycle through a small number of conversation slots, so opening many agents reuses earlier slots rather than piling up panes. `max_vertical_panes` caps how many chat panes are visible at once.

## Foreground vs. background

The TUI exists only in a foreground run (`aiur` or `aiur --bg --interactive`). `aiur --bg` runs headless with no board or panes and keeps the dashboard and control commands for observation — that is the shape an agent Executor drives. `aiur --debug` additionally records each chat pane to `log/record/chat.<issue>.ansi` while the run is attached, which is the durable record of what a chat pane rendered.
