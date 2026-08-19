# AIUR

Oversee a fleet of coding agents that coordinate via events.

## Install

```bash
npm install --global aiur-cli
```

## Usage

```bash
cd your-repo
aiur init     # interactive setup wizard
aiur
```

`aiur init` scaffolds `.aiur/config` and provisions the repo: tracker and
repository, agent backends and routing, concurrency and turn limits, the GitHub
token, and the `agent:*` lifecycle labels. Re-running resumes from your saved
answers. When setup finishes, label the issues you want worked `agent:todo` and
run `aiur`.

## Features

- **Issue Monitoring** — Dispatch agents automatically via GitHub or Linear tickets.
- **Shared Bus** — Agents auto-pub/sub to dependency events, unblocking work early.
- **Optimize Effort** — Story points guide model sizes and skills across Claude and Codex.
- **Take the Wheel** — Drive at any moment via pre-warmed [Opencode](https://opencode.ai) sessions in configurable tmux panes.
- **Smart Alerts** — Customizable notifications and sounds when agents finish, stall, or need a decision.
- **Live Dashboard** — Shareable web view of every agent, event, and progress bar.
- **Build Orders** — Plan a large feature into typed members, lanes, phases, and dependencies, dispatched in dependency-safe parallel batches.
- **Analytics** — Live-run telemetry: lifecycle time, concurrency, complexity tiers, and cost over a chosen window.
- **Stream Deck** — Elgato Stream Deck + keys ranked by urgency, with pause/resume, a live log surface, and hold-to-dictate voice messages.
- **Hyper Optimized** — Monitors API and model token usage, routes on peak pricing and other factors, and supports Cloudflare and more.

The TUI and GUI are both optional: `aiur --bg` runs headless with the GUI, and
`--no-dashboard` drops the web listener. Every usable GUI requires
`AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD` — without them the loopback
listener binds but refuses every request until both are set. The GUI is writable
by default, and writable mode requires those same two credentials even on loopback.

## Interfaces

### GUI

![The Units page of the GUI](https://aiur.team/images/dashboard/units-dark.png)

The GUI is the browser interface for supervising a run: the Units fleet table
and meters, the Commands decision inbox, Build Order graphs, and Analytics.

### TUI

![The Aiur TUI: the agent-list board and a chat pane](https://aiur.team/images/tui/aiur-tui.gif)

The TUI is a live agent board in your terminal with chat panes opened into
individual agent sessions. Press `enter` on a row to open its conversation,
`space` to pause or resume, `←` / `→` to change the concurrency cap, and `?`
for the full keymap. A later bare `aiur` from the same project attaches to that
live directory-scoped session; detaching leaves the run healthy.

### CLI

| Command | What it does |
| --- | --- |
| `aiur init` | Interactive setup wizard |
| `aiur` | Start a foreground TUI, or attach to this directory's live session |
| `aiur --bg` | Start a detached headless run, GUI still served |
| `aiur status` | Daemon state, active agents, and the current concurrency cap |
| `aiur alerts --needs-attention` | Unresolved items waiting on you |
| `aiur pause <id…>` / `aiur resume <id…>` | Pause or resume agents by issue id |
| `aiur message <id> "<text>"` | Send text into a live agent session |
| `aiur set max-agents <n>` | Change the concurrency cap without restarting |
| `aiur --todo <id…> [--only]` | Queue tickets; `--only` dequeues the rest |
| `aiur stop` / `aiur restart` | Stop the session, or refresh the release and restart |

## License

> [!WARNING]
> **Use at your own risk.** Aiur is an unstable, vibecoded engineering preview
> for trusted environments only. It **bypasses all agent permission prompts**
> and has very few efficiency optimizations. Suggested for simple tasks under
> supervision.
>
> Provided "as is", without warranty of any kind. You assume all risk for any
> cost, token spend, data loss, or damage from running it.

This project is licensed under the [Apache License 2.0](LICENSE).
