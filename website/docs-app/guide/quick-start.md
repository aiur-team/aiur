# Quick start

## Install

Install the npm package with Node.js (the hosted quick-start uses Node 20):

```bash
npm install -g aiur-cli
```

## Initialize

Run `aiur init` in the repository you want Aiur to work on. It detects the available agent toolchains, scaffolds `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`, and `.aiur/alerts`, prepares the repository state node, and offers a pre-warmed base build with a sibling `.aiur/prewarm` script. For GitHub setups it also writes `./.env` for `GITHUB_TOKEN`; the wizard explains how to provide the token rather than prompting for the secret directly. Use `aiur init --force` to recreate the config while preserving sibling scaffold files.

The wizard asks for:

- tracker and repository settings;
- agent backends, routing, limits, and toolchain readiness;
- the GitHub token setup instructions and lifecycle labels.

Add `agent:todo` to the issues you want worked.

## First run

The bare `aiur` command discovers `.aiur/config` and starts a foreground run. `aiur run` is the explicit-verb equivalent.

Set `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD` before the default writable dashboard can start, including on loopback. Alternatively set `observability.dashboard_writable: false` for an unauthenticated loopback dashboard. The launch output prints the dashboard URL only when the listener starts. Continue with the [Dashboard](/guide/executor-control-center) guide.

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
| `aiur message <id> "<text>"` | Send an Executor message through the agent’s native queue. |
| `aiur --todo <ids…> [--only]` | Queue selected tickets; `--only` dequeues other pending tickets. |

See the [CLI](/reference/cli) reference for the complete operational surface, and [Executor](/concepts/executor) for what the role you have just taken on actually involves.
