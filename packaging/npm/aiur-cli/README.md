# AIUR

**AI Unit Runtime for Executors**

Oversee a fleet of coding agents that **coordinate via events**.

> [!WARNING]
> **Use at your own risk.** Aiur is an unstable, vibecoded engineering preview for trusted
> environments only. It **bypasses all agent permission prompts** and has very few efficiency
> optimizations. Suggested for simple tasks under supervision.
>
> Provided "as is", without warranty of any kind. You assume all risk for any cost, token
> spend, data loss, or damage from running it.

## Install

```bash
npm install -g aiur-cli
```

Requires [tmux](https://github.com/tmux/tmux) at runtime. Install
[opencode](https://opencode.ai) too for in-pane agent chat.

When a newer `aiur-cli` is published, a one-line update notice is printed to
stderr (checked in the background at most once a day, never blocking your
command). Set `AIUR_NO_UPDATE_NOTIFIER=1` to silence it; it is also skipped under
CI (`CI=true`).

## Get started

```bash
cd your-repo
aiur init     # interactive setup wizard
aiur          # start agents (foreground); use `aiur --bg` to detach
```

`aiur init` scaffolds `.aiurconfig` and provisions the repo. It walks you through:

1. **Where to store config** — repo-local `./.aiurconfig` or global `~/.aiurconfig`.
2. **Tracker** — GitHub or Linear, plus the repo.
3. **Agents & routing** — Claude and/or Codex, optional per-complexity model
   routing, and the permission mode.
4. **Limits** — max concurrent agents, turns, duration, pre-warmed sessions, and
   polling interval.
5. **GitHub token** — to create labels and act as the bot account.
6. **Labels** — the lifecycle (`agent:*`), complexity, model, and remote-control
   labels aiur routes on. Only missing labels are created; a group that already
   exists is reported as created and skipped.

Re-running resumes from your saved answers. When setup finishes, add `agent:todo`
to the issues you want worked and run `aiur`.

## Commands

| Command | What it does |
|---|---|
| `aiur init` | Interactive setup wizard (scaffold `.aiurconfig`) |
| `aiur` | Start the workflow in the foreground (local-only bind) |
| `aiur --bg` | Start a detached headless BEAM with the web dashboard enabled |
| `aiur --bg --no-dashboard` | Start a lean detached headless BEAM without the dashboard |
| `aiur --no-dashboard` | Keep the foreground terminal UI without the dashboard |
| `aiur status` | Show active agents and their state |
| `aiur analytics [--range run\|full] [--since <ISO-8601>] [--until <ISO-8601>] [--build-order <id>] [--json]` | Render the Analytics dashboard snapshot for an explicit chart window |
| `aiur alerts [--needs-attention]` | Show structured alert feed JSON lines |
| `aiur pause <id…>` / `resume <id…>` | Pause or resume agents by issue ID |
| `aiur --todo <id…> [--only]` | Queue GitHub tickets; optionally dequeue all other pending tickets |
| `aiur stop` | Stop the running session |

`aiur analytics` reads the same durable telemetry projection as `/analytics`.
It prints the resolved chart window plus the freshness, observation time, and
age of each data source; `--json` returns the same information in a stable
envelope. The explicit window applies to the time charts, as the dashboard
brush does; its page KPIs and complexity tiers remain scoped to the selected
run or Build Order. `--range run` is the default (the current session), while
`--range full` includes prior materialized sessions. `--build-order` scopes the snapshot
to a selected Build Order's typed members.
Provider spend remains explicitly unavailable unless the command is given the
same financial-data capability that the dashboard connection uses; it is never
silently reported as zero.

`aiur --todo` works without a running daemon and derives its repository and
labels from the current config. `--only` leaves tickets already in progress
untouched. Concurrent `--only` invocations are not coordinated across
processes; running two overlapping `aiur --todo ... --only` commands can drop
each other's tickets, so avoid running them at the same time.

If a control command times out while the daemon is still live, the host may be
scheduler-saturated. Run `aiur stop` to interrupt that session and its workers,
then start it again; this is a session-level recovery action, not a cooperative
single-agent pause.

## Features

- **Issue Monitoring** — Dispatch agents automatically via GitHub or Linear tickets.
- **Shared Bus** — Agents auto-pub/sub to dependency events, unblocking work early.
- **Optimize Effort** — Story points guide model sizes and skills. Supports Claude and Codex.
- **Take the Wheel** — Drive at any moment via pre-warmed [Opencode](https://opencode.ai) sessions in configurable tmux panes.
- **Smart Alerts** — Customize notifications and sounds when agents finish, stall, or need a decision.
- **Live Dashboard** — Shareable web view of every agent, event, and progress bar.

Background mode is headless inside Aiur: it skips the interactive agent-list and
chat/prewarm panes, but serves the dashboard at the configured host and port.
Use `--bg --no-dashboard` for the lean no-listener shape. `--no-dashboard` also
works in foreground mode without removing the terminal UI. Non-loopback binds
still require both dashboard Basic Auth environment variables. The launcher
keeps one detached tmux session as the BEAM lifetime holder. Re-running
`aiur --bg` against a live session exits with an already-running hint; stale
tmux state is cleaned up before restart.

Claude Remote Control lifecycle hooks require the HTTP server. Aiur rejects a
`--no-dashboard` launch when `agent.remote_control` is enabled or an
`agent.routing` value uses `+remote`; remove the flag or disable that Remote
Control configuration. Runtime `model:remote` dispatch and live promotion are
also refused unless the HTTP listener is confirmed bound. A background launch
prints that confirmed URL, or an explicit listener-unavailable warning.

---

_Command macro, delegate micro, maximize APM._

[github.com/aiur-team/aiur](https://github.com/aiur-team/aiur)
