# Quick start

## Install

Install the npm package with Node.js (the hosted quick-start uses Node 20):

```bash
npm install -g aiur-cli
```

## Initialize

Run `aiur init` in the repository Aiur should operate.

| Setup step | Result |
| --- | --- |
| Detect tools | Finds available agent toolchains. |
| Scaffold | Writes `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`, and `.aiur/alerts`. |
| Prepare state | Creates the repository state node and optional `.aiur/prewarm`. |
| GitHub auth | Writes `./.env` guidance for `GITHUB_TOKEN` without prompting for the secret. |
| Recreate | `aiur init --force` refreshes config while preserving sibling scaffold files. |
| Route agents | Collects backends, models, limits, readiness, and lifecycle labels. |

Add `agent:todo` to the issues you want worked. Prefer GitHub App installation-token authentication over a personal access token; see [GitHub](/apis/github#github-app-authentication) to set it up.

## First run

The bare `aiur` command discovers `.aiur/config`, starts a foreground run when this repository has no live session, attaches to its directory-scoped tmux session when one is already running, and leaves `aiur run` as the explicit launch form.

| Dashboard mode | Requirement |
| --- | --- |
| Writable | Set `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`, including on loopback. |
| Read-only loopback | Set `observability.dashboard_writable: false` and configure both dashboard credentials. Without them the listener may bind, but every dashboard request returns `503`. |
| Listener disabled | No URL is printed. |

Continue with the [Dashboard](/guide/executor-control-center) guide.

## Core subcommands

| Command | What it does |
| --- | --- |
| `aiur --bg` | Start a headless detached run with the dashboard enabled. |
| `aiur --bg --no-dashboard` | Start a lean detached run without the dashboard. |
| `aiur status` | Show a table of active agents and their running, paused, or idle state. |
| `aiur agents` | Show per-agent activity with runtime and current activity. |
| `aiur watch` | Show a one-shot board of tickets, state, and what each agent is doing; add `--interval <secs>` to refresh continuously. |
| `aiur pause <ids…>` / `aiur pause --all` | Cooperatively pause agents by issue id. |
| `aiur resume <ids…>` / `aiur resume --all` | Resume paused agents by issue id. |
| `aiur stop` | Stop this instance's session (BEAM + tmux). |
| `aiur restart` | Stop the session, refresh the release, and start it again detached. Add `--no-build` to bounce on the release already on disk. |
| `aiur --max-agents <n>` | Override the concurrent-agent cap at launch. |
| `aiur set max-agents <n>` | Change the concurrent-agent cap while the run is active. |
| `aiur message <id> "<text>"` | Queue an Executor message on the agent’s native queue. It reports whether the agent claimed the message or it is still queued. |
| `aiur --todo <ids…> [--only]` | Queue selected tickets; `--only` dequeues other pending tickets. |

See [CLI and control commands](/reference/cli) for the complete operational surface.
