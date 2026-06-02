# Aiur

Aiur runs autonomous coding agents against the work in your tracker, lands the resulting
PRs, and lets you watch and chat with each agent in real time.

> [!WARNING]
> Aiur is prototype software intended for evaluation only and is presented as-is.

## How it works

1. **Polls a tracker** (Linear, GitHub Issues, or in-memory) for candidate work.
2. **Creates an isolated workspace** per selected item and clones your repo into it.
3. **Launches a coding agent** (Codex or Claude) inside the workspace with your `.aiurconfig`
   YAML config and prompt template.
4. **Drives the run** through repeated turns until the item reaches a terminal state
   (`Done`, `Closed`, `Cancelled`, `Duplicate`), then cleans up the workspace.

Aiur ships with a multi-pane CLI that shows every active agent at a glance, lets you open
any agent in an opencode-backed chat pane, and send messages directly into a running
session. A LiveView dashboard at `/` covers the same surface for browser-based operators.

In the CLI agent list, `Enter` opens the selected agent opencode pane and `Space`
pauses or resumes execution for the selected agent. Navigate above the first agent row
to focus the active-agent limit, then use `Left` / `Right` to decrease or increase the
session-only maximum. The config file remains unchanged; restarting Aiur reloads the
configured limit.

## Quickstart

```bash
git clone https://github.com/its-everdred/aiur
cd aiur
mise install
cd src && ../scripts/aiur init   # scaffolds .aiurconfig in the current repo
# Or copy a starter pair (the config's prompt_file: points at the sibling template):
#   cp examples/workflows/linear-codex.aiurconfig .aiurconfig
#   cp examples/workflows/linear-codex.prompt.md linear-codex.prompt.md
# Edit .aiurconfig for your tracker, repo, credentials, and workspace.
export PATH="$PWD/scripts:$PATH"
aiur ./.aiurconfig
```

[mise](https://mise.jdx.dev/) is the recommended runtime manager — `mise.toml` pins
versions for you. On first run, the `aiur` wrapper fetches Hex dependencies,
compiles the Elixir app, and builds `bin/aiur`; later runs only rebuild when
sources change.

Install [opencode](https://opencode.ai) separately for CLI chat panes. Aiur starts
`opencode serve` lazily per pane and routes its OpenAI-compatible provider calls
back through Aiur on `opencode.bridge_host` / `opencode.bridge_port`.

## Config

An `.aiurconfig` file is pure YAML for adapters, credentials, and run policy. An
optional `prompt_file:` key points at a sibling Markdown/Liquid template used as the
agent prompt; when omitted, a built-in default prompt is used. Supported adapters:

- **Trackers**: `linear`, `github`, `memory`
- **Agents**: `codex`, `claude`

Copy one of the starter pairs (config + prompt template) and edit it for your project:

- [examples/workflows/linear-codex.aiurconfig](examples/workflows/linear-codex.aiurconfig)
- [examples/workflows/github-codex.aiurconfig](examples/workflows/github-codex.aiurconfig)
- [examples/workflows/github-claude.aiurconfig](examples/workflows/github-claude.aiurconfig)

If `.aiurconfig` is missing or has invalid YAML at startup, Aiur won't boot. If a later
reload fails, Aiur keeps running with the last known good config and logs the error
until the file is fixed.

## Operating with `aiur`

`scripts/aiur` wraps `./bin/aiur` with named profiles, foreground/background modes,
operator controls, and a `stop` verb. It autodetects Linux (systemd `--user`) vs
macOS (`nohup` + PID file). On a fresh clone it also runs `mix deps.get`,
`mix compile`, and `mix release --overwrite` before launching Aiur.
Put `scripts/` on your `PATH`:

```bash
export PATH="$PWD/scripts:$PATH"
aiur list
```

| Command | What it does |
|---|---|
| `aiur` | Attach to the default profile's existing tmux session, or start it in the foreground with a local-only bind |
| `aiur <profile>` | Attach to the profile's existing tmux session, or start it in the foreground |
| `aiur --fresh [profile]` | Start a fresh foreground session even when a tmux session already exists |
| `aiur run <profile>` | Named profile, fresh foreground session |
| `aiur --bg [profile\|all]` | Background mode |
| `aiur stop [profile\|all]` | Stop foreground processes and background services |
| `aiur list` | Show configured profiles |
| `aiur build` | Rebuild `bin/aiur` |
| `aiur status` | Show active agents and their running/paused/idle state |
| `aiur pause <id...>` | Cooperatively pause one or more running agents by issue ID |
| `aiur pause --all` | Cooperatively pause the currently running/paused agent snapshot |
| `aiur resume <id...>` | Resume one or more paused agents by issue ID |
| `aiur resume --all` | Resume the currently paused agent snapshot |
| `aiur <path-to-.aiurconfig>` | Ad-hoc config |

Pause and resume target issue IDs, not process IDs. Space-separated and
comma-separated forms are both accepted:

```bash
aiur pause 44
aiur pause 44 45 46
aiur pause 44,45,46
aiur resume 44
aiur status
```

Pause is cooperative: the running agent receives the same pause request used by the
dashboard and agent-list pane, then stops at its next safe turn boundary. Pausing an
already-paused agent is a no-op and exits successfully.

Profiles live at `~/.config/aiur/aiur.profiles` (six pipe-separated fields per line:
`name|root|workflow|port|logs_root|service`). Environment overrides come from
`~/.config/aiur-dashboard.env`, `.env`, and `.env.local` in that order. `.env*` are
gitignored at the repo root.

By default `aiur` injects `--host 127.0.0.1` so the dashboard stays local. Pass `--host`
explicitly to opt out.

Use `--port <N>` before the command/profile name to override the configured profile or
workflow port for one invocation:

```bash
aiur --port 4099
aiur --port 4099 --bg
aiur --port 4102 actions
```

When no `--port` override is present and the configured port is busy, the wrapper tries
the next 9 ports and prints the selected port. If none are free, a fast startup crash is
replayed in the host shell with the last pane output and a port-collision hint.

## Dashboard

When `server.port` (or CLI `--port`) is set, Aiur exposes:

- LiveView dashboard at `/` — active agents, logs, per-agent chat modal
- JSON API under `/api/v1/*` for operational debugging

## Configuration notes

- Path values support `~` for the home directory and `$VAR` for environment substitution.
- Codex defaults to safer policies when omitted (`approval_policy` rejects unprompted
  approvals, `thread_sandbox` is `workspace-write`).
- `agent.max_turns` caps how many back-to-back backend turns Aiur runs in a single
  invocation when a turn completes but the issue is still active. Default: `20`.
- `agent.max_concurrent_agents` caps active workers only. Paused agents remain visible
  and can keep their panes open without consuming an active slot.
- Use `hooks.after_create` to bootstrap a fresh workspace (typically a `git clone`).
- Optional local alert sounds: see `alerts.yaml` at the repo root.

## Testing

```bash
make all
```

`make e2e` runs a live end-to-end test against real Linear + Codex; it creates and tears
down disposable resources and requires `LINEAR_API_KEY`.

## Project layout

- `lib/` — application code
- `test/` — ExUnit suite
- `scripts/aiur` — operator wrapper
- `examples/workflows/` — starter config + prompt-template pairs
- `.aiurconfig` — the config contract for in-repo runs

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
