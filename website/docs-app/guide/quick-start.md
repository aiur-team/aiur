# Quick start

## Install

Install the npm package with Node.js (the hosted quick-start uses Node 20):

```bash
npm install -g aiur-cli
```

## Prerequisites

| Tool | Why you need it |
| --- | --- |
| Node.js | Runs the `aiur-cli` npm package. |
| `gh` (GitHub CLI) | Authenticates with GitHub. Run `gh auth login` once — the boot gate falls back to the `gh` keyring, so no manual `GITHUB_TOKEN` export is required. |
| `tmux` | The launcher runs each Aiur daemon in its own detached tmux session. |
| A tracker repository | The repository `aiur init` is pointed at, with issues carrying `agent:todo`. |

`python3` is optional: it powers the local budget broker, and without it the daemon runs GitHub requests unmetered. Everything below the baseline is optional — see [Optional Optimizations](/reference/optional-optimizations) for what you can turn on and what it costs.

## Initialize

Run `aiur init` once for your first setup. Choose **global** to store reusable defaults in `~/.aiur/config`; any project without local config can reuse them.

With global defaults already present, run `aiur` in another GitHub repository without running `init` there. Aiur announces the fallback, infers the target from `origin`, and ensures workflow/marker and complexity labels before dispatch.

It does not create model, effort, or alias labels; models and complexity routing come from config. Existing model overrides remain supported.

Keep reusable credentials in `~/.aiur/.env` (outside Git), or use configured GitHub App credentials or `gh auth login`. Missing labels require Issues read/write permission; startup stops with an actionable error if setup fails. When required labels already exist, no label writes are made.

Omit `tracker.github.repo` from portable global defaults; a different explicit repo is rejected rather than modifying the wrong repository. Global branch and agent settings still apply, so use local `aiur init` when a repository needs different settings.

A repository-local `.aiur/config` takes precedence; use `init` for repository-specific configuration.

Each repository needs an authorized dispatch operator and the configured base branch with accepted prerequisites. Establish `.github/CODEOWNERS` with the approved human owner, or use explicit `tracker.github.allowed_users`; missing fallback trust denies dispatch.

Worker pushes and PR publication need Write access in addition to issue reads. See [GitHub permissions](/apis/github) for credential setup; the Executor reports access or setup blockers before describing workers as active.

The wizard offers these setup steps:

| Setup step | Result |
| --- | --- |
| Detect tools | Finds available agent toolchains. |
| Scaffold | Writes `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`, and `.aiur/alerts`. |
| Prepare state | Creates the repository state node and optional `.aiur/prewarm`. |
| GitHub auth | Defaults to `GITHUB_TOKEN` and offers GitHub App setup as an optional upgrade when agents are hitting rate limits. A `gh auth login` keyring credential also satisfies the boot gate. |
| Recreate | `aiur init --force` refreshes config while preserving sibling scaffold files. |
| Route agents | Collects backends, models, limits, readiness, and lifecycle labels. |

Add `agent:todo` to the issues you want worked. If agents are hitting rate limits, consider the optional [GitHub App setup](/apis/github#github-app-authentication).

GitHub Free does not expose rulesets or classic branch protection for private repositories. When GitHub reports that plan limit during CI-readiness setup, `aiur init` shows GitHub's explanation and continues without saving a full readiness assessment. Make the repository public or upgrade its plan to enable that verification.

## First run

The bare `aiur` command discovers `.aiur/config`, starts a foreground run when this repository has no live session, attaches to its directory-scoped tmux session when one is already running, and leaves `aiur run` as the explicit launch form.

| Dashboard mode | Requirement |
| --- | --- |
| No credentials | The loopback listener binds but every dashboard request is refused until `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD` are set (a writable dashboard issues a basic-auth challenge; a read-only one returns `503` naming both variables). A dashboard bound beyond loopback refuses to start at all. |
| Writable (default) | `observability.dashboard_writable: true` (the default) and both `AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD`, including on loopback. |
| Read-only | `observability.dashboard_writable: false`; both credentials are still required to view the dashboard. |
| Listener disabled | `--no-dashboard`; no URL is printed. |

Continue with the [GUI](/guide/gui) guide.

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
