# AIUR

**AI Unit Runtime for Executors**

Oversee a fleet of coding agents that **coordinate via events**.

Aiur watches your issue tracker, dispatches one agent per ticket into its own
workspace and checkout, and gives you four ways to supervise the fleet instead
of babysitting individual coding sessions.

> [!WARNING]
> **Use at your own risk.** Aiur is an unstable, vibecoded engineering preview for trusted
> environments only. It **bypasses all agent permission prompts** and has very few efficiency
> optimizations. Suggested for simple tasks under supervision.
>
> Provided "as is", without warranty of any kind. You assume all risk for any cost, token
> spend, data loss, or damage from running it.

## Get started

```bash
npm install -g aiur-cli   # Node.js 18+

cd your-repo
aiur init                 # interactive setup wizard
aiur                      # start the run
```

`aiur init` scaffolds `.aiur/config` and provisions the repo: tracker and
repository, agent backends and routing, concurrency and turn limits, the GitHub
token, and the `agent:*` lifecycle labels. Re-running resumes from your saved
answers.

When setup finishes, label the issues you want worked `agent:todo` and run
`aiur`.

| Requirement | Why |
| --- | --- |
| [tmux](https://github.com/tmux/tmux) | Runtime for the TUI and agent panes |
| [opencode](https://opencode.ai) | In-pane agent chat (provisioned on install) |
| Claude Code or Codex | The agents themselves |

## The four surfaces

| Surface | What it gives you | How to open it |
| --- | --- | --- |
| **CLI** | Scriptable control of a run from any shell | `aiur status`, `aiur pause 142` |
| **TUI** | Live agent board plus chat panes, in your terminal | `aiur` (foreground) |
| **Dashboard** | Browser view of the fleet, decisions, and analytics | `http://127.0.0.1:4000` |
| **Stream Deck** | Physical keys and dictation for the fleet | Separate sidecar, see below |

### CLI

| Command | What it does |
| --- | --- |
| `aiur init` | Interactive setup wizard |
| `aiur` | Start the run in the foreground with the TUI |
| `aiur --bg` | Start a detached headless run, dashboard still served |
| `aiur status` | Daemon state, active agents, and the current concurrency cap |
| `aiur alerts --needs-attention` | Unresolved items waiting on you |
| `aiur pause <id…>` / `aiur resume <id…>` | Pause or resume agents by issue id |
| `aiur message <id> "<text>"` | Send text into a live agent session |
| `aiur set max-agents <n>` | Change the concurrency cap without restarting |
| `aiur --todo <id…> [--only]` | Queue tickets; `--only` dequeues the rest |
| `aiur stop` / `aiur restart` | Stop the session, or refresh the release and restart |

Add `--no-dashboard` to either mode to skip the web listener.

### TUI

The foreground run opens a tmux board with one row per ticket, showing runtime,
turn count, backend, pinned model, and a state glyph. Press `enter` on a row to
open that agent's chat pane beside the board, `space` to pause or resume, `←`
and `→` to change the concurrency cap, and `?` for the full keymap.

### Dashboard

Served on foreground and `--bg` runs at the host and port in your config,
`http://127.0.0.1:4000` by default. The launch output prints the real URL.

| Page | What it shows |
| --- | --- |
| Units | Fleet table, ticket backlog, provider rate meters |
| Commands | Durable decision inbox: answer, revise, retry delivery |
| Build Order | Ticket dependency graph and phases |
| Analytics | Throughput, complexity tiers, and spend over a chosen window |

Writable mode is the default and requires `AIUR_DASHBOARD_USERNAME` and
`AIUR_DASHBOARD_PASSWORD`, even on loopback. Set
`observability.dashboard_writable: false` for an unauthenticated read-only
loopback dashboard. Basic Auth is unencrypted, so put a TLS proxy in front of any
non-loopback bind.

### Stream Deck

An Elgato Stream Deck + can drive the fleet: agent keys ranked by urgency, pause
and resume, a live log surface, and hold-to-dictate voice messages. A browser
emulator of the same layout is at `/streamdeck` on the dashboard.

> The physical sidecar is **experimental** and ships separately from this
> package, as a Linux x64 archive (glibc 2.28+, systemd user session). It is not
> installed by `npm install aiur-cli`. See the
> [Stream Deck guide](https://aiur.team/docs/guide/stream-deck).

## Update notices

When a newer `aiur-cli` is published, a one-line notice is printed to stderr,
checked in the background at most once a day and never blocking your command.
Set `AIUR_NO_UPDATE_NOTIFIER=1` to silence it; it is skipped under CI.

Prerelease builds are published under the `nightly` dist-tag and never reach
`latest`, so a plain `npm install -g aiur-cli` always gives you a stable release.
To try one: `npm install -g aiur-cli@nightly`.

---

_Command macro, delegate micro, maximize APM._

[github.com/aiur-team/aiur](https://github.com/aiur-team/aiur)
