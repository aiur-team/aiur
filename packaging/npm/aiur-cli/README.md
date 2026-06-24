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
| `aiur --bg` | Start a headless BEAM in one detached tmux lifetime session |
| `aiur status` | Show active agents and their state |
| `aiur pause <id…>` / `resume <id…>` | Pause or resume agents by issue ID |
| `aiur stop` | Stop the running session |

## Features

- **Issue Monitoring** — Dispatch agents automatically via GitHub or Linear tickets.
- **Shared Bus** — Agents auto-pub/sub to dependency events, unblocking work early.
- **Optimize Effort** — Story points guide model sizes and skills. Supports Claude and Codex.
- **Take the Wheel** — Drive at any moment via pre-warmed [Opencode](https://opencode.ai) sessions in configurable tmux panes.
- **Smart Alerts** — Customize notifications and sounds when agents finish, stall, or need a decision.
- **Live Dashboard** — Shareable web view of every agent, event, and progress bar.

Background mode is headless inside Aiur: it skips the interactive agent-list
pane, chat/prewarm panes, and dashboard unless you explicitly opt into a
dashboard port. The launcher still keeps one detached tmux session as the BEAM
lifetime holder. Re-running `aiur --bg` against a live session exits with an
already-running hint; stale tmux state is cleaned up before restart.

---

_Command macro, delegate micro, maximize APM._

[github.com/its-everdred/aiur](https://github.com/its-everdred/aiur)
