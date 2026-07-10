# Quick start

## Install

Install the npm package with Node.js (the hosted quick-start uses Node 20):

```bash
npm install -g aiur-cli
```

## Initialize

Run `aiur init` in the repository you want Aiur to work on. It scaffolds `.aiur/config`, `.aiur/hooks`, and `.aiur/prompt.md`. For GitHub setups it also writes `./.env` for `GITHUB_TOKEN`; the wizard explains how to provide the token rather than prompting for the secret directly. Use `aiur init --force` to recreate the config while preserving sibling scaffold files.

The wizard asks for:

- tracker and repository settings;
- agent backends, routing, and limits;
- the GitHub token setup instructions and lifecycle labels.

Add `agent:todo` to the issues you want worked.

## First run

The bare `aiur` command discovers `.aiur/config` and starts a foreground run. `aiur run` is the explicit-verb equivalent.

## Core subcommands

| Command | What it does |
| --- | --- |
| `aiur --bg` | Start a headless detached background run. |
| `aiur status` | Show a table of active agents and their running, paused, or idle state. |
| `aiur agents` | Show per-agent activity with runtime and current activity. |
| `aiur watch` | Show a one-shot board of tickets, state, and what each agent is doing; add `--interval <secs>` to refresh continuously. |
| `aiur pause <ids…>` / `aiur pause --all` | Cooperatively pause agents by issue id. |
| `aiur resume <ids…>` / `aiur resume --all` | Resume paused agents by issue id. |
| `aiur stop` | Stop this instance's session (BEAM + tmux). |
| `aiur --max-agents <n>` | Override the concurrent-agent cap at launch. |
