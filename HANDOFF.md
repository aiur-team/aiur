# Symphony Local Handoff

This branch exists to hand the local Symphony setup to the next agent/operator.

Do not commit secrets. The machine-local secrets live outside this repo.

## Repository State

- Main repo: `/home/orangekid/github/symphony`
- Remote fork: `git@github.com:its-everdred/symphony.git`
- Upstream: `https://github.com/openai/symphony.git`
- Current durable branch with this document: `handoff`
- `main` has already been fast-forwarded and pushed with the dashboard/log work.

Important local branch history now merged into `main`:

- GitHub Issues tracker config in `elixir/WORKFLOW.md`
- GitHub workflow documentation in `README.md`
- per-workspace agent logs under `logs/agent.md` and `logs/agent.ndjson`
- dashboard modal for viewing per-agent logs
- chat-style log modal with overflow protection
- `AGENTS.local.md` ignored for machine-local notes

## Related Claude App Server

There is a sibling repo:

```text
/home/orangekid/github/symphony-claude
```

Its remote is:

```text
git@github.com:its-everdred/claude-app-server.git
```

It provides `symphony-claude`, a JSON-RPC 2.0 app server that adapts Claude Code to the Codex/Symphony app-server protocol.

Setup from source:

```bash
cd /home/orangekid/github/symphony-claude
pnpm install
pnpm run build
```

Claude auth is handled by the Claude CLI, not by an API key:

```bash
claude auth
```

Useful commands:

```bash
pnpm run build
pnpm run start
pnpm run start:no-tls
node dist/index.js start --port 3284
```

The Symphony repo currently runs Codex in `elixir/WORKFLOW.md`. To use Claude instead, wire Symphony's agent command to the `symphony-claude` app server once the Claude adapter path is selected and tested.

## Local Symphony Build

Requirements already used on this machine:

- `mise`
- Erlang/Elixir managed by `mise`
- `pnpm`
- `gh`
- Codex CLI
- optional Claude CLI for `symphony-claude`

Build Symphony:

```bash
cd /home/orangekid/github/symphony/elixir
mise install
pnpm install
mise exec -- mix deps.get
mise exec -- mix escript.build
```

Focused validation used during this work:

```bash
cd /home/orangekid/github/symphony/elixir
mise exec -- mix test test/symphony_elixir/extensions_test.exs
mise exec -- mix format --check-formatted lib/symphony_elixir_web/live/dashboard_live.ex priv/static/dashboard.css test/symphony_elixir/extensions_test.exs
mise exec -- mix escript.build
```

Note: full format checking previously found pre-existing unrelated formatting drift in other files. Do not conflate that with the dashboard work unless you choose to clean it deliberately.

## Local Service

The active user service for `orangekid` is:

```text
/home/orangekid/.config/systemd/user/symphony.service
```

Current shape:

```ini
[Unit]
Description=Symphony

[Service]
WorkingDirectory=/home/orangekid/github/symphony/elixir
EnvironmentFile=/home/orangekid/.config/symphony-dashboard.env
ExecStart=/home/orangekid/.local/bin/mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails /home/orangekid/github/symphony/elixir/WORKFLOW.md
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

Manage it:

```bash
systemctl --user status symphony
systemctl --user start symphony
systemctl --user stop symphony
systemctl --user restart symphony
journalctl --user -u symphony -n 100 --no-pager
```

After code changes, rebuild then restart:

```bash
cd /home/orangekid/github/symphony/elixir
mise exec -- mix escript.build
systemctl --user restart symphony
```

At handoff time the service was intentionally stopped at the user's request.

## Dashboard

Configured in `elixir/WORKFLOW.md`:

```yaml
server:
  host: 100.81.109.51
  port: 4000
```

Known URL:

```text
http://agents.amicooked.chat:4000
```

Direct Tailscale URL:

```text
http://100.81.109.51:4000
```

Security model:

- Tailscale reachability required.
- Basic Auth required.
- Basic Auth values live in `/home/orangekid/.config/symphony-dashboard.env`.
- Do not print or commit the username/password or token.

If using curl for debugging, use environment variable names only and avoid showing expanded values in logs or chat.

## Machine-Local Env

Env file:

```text
/home/orangekid/.config/symphony-dashboard.env
```

Expected variables include:

```bash
SYMPHONY_BASIC_AUTH_USERNAME=...
SYMPHONY_BASIC_AUTH_PASSWORD=...
GITHUB_TOKEN=...
```

The GitHub token must be valid for the GitHub Issues workflow below.

## GitHub Issues Workflow

Active workflow file:

```text
/home/orangekid/github/symphony/elixir/WORKFLOW.md
```

It is configured for:

```yaml
tracker:
  kind: github
github:
  repo: its-applekid/actions
  label_prefix: agent
```

The issue runner works in:

- fork/origin: `its-applekid/actions`
- upstream/base: `ethereum-optimism/actions`

It should:

- read issues from `its-applekid/actions`
- clone `git@github.com:its-applekid/actions.git`
- add upstream `git@github.com:ethereum-optimism/actions.git`
- create branches named `symphony/<issue-number>`
- push only to the fork
- open PRs into `ethereum-optimism/actions:main`
- never push directly to `ethereum-optimism/actions`

Labels:

- `agent:todo`
- `agent:in-progress`
- `agent:human-review`
- `agent:rework`
- `agent:merging`
- `agent:done`

Current useful issue context:

- Issue `its-applekid/actions#2` was used for testing.
- It was blocked by invalid GitHub auth.
- The user said they will fix the GitHub auth token.

## GitHub Auth

There are two auth paths:

1. `GITHUB_TOKEN` in `/home/orangekid/.config/symphony-dashboard.env`
2. `gh` auth state in `/home/orangekid/.config/gh/hosts.yml`

The workflow prompt expects local `gh` auth for `its-applekid`.

Check:

```bash
gh auth status
```

If `gh` says it is logged in as the wrong account or the saved token is invalid:

```bash
gh auth logout -h github.com -u <wrong-user>
gh auth login -h github.com
gh auth status
```

Use a token for the `its-applekid` account with access to `its-applekid/actions`.

Fine-grained token URL:

```text
https://github.com/settings/personal-access-tokens/new
```

Minimum intended permissions:

- Repository access: `its-applekid/actions`
- Contents: read/write
- Issues: read/write
- Pull requests: read/write
- Metadata: read-only

If the agent must create PRs against `ethereum-optimism/actions`, verify the token/account can open cross-repo PRs from `its-applekid/actions`.

## Workspaces And Logs

Workspace root:

```text
/home/orangekid/code/symphony-workspaces
```

Per-issue workspace:

```text
/home/orangekid/code/symphony-workspaces/<issue-number>
```

Agent log files:

```text
/home/orangekid/code/symphony-workspaces/<issue-number>/logs/agent.md
/home/orangekid/code/symphony-workspaces/<issue-number>/logs/agent.ndjson
```

If a run is thrashing on stale state:

```bash
systemctl --user stop symphony
rm -rf /home/orangekid/code/symphony-workspaces/<issue-number>
systemctl --user start symphony
```

Only remove the specific issue workspace. Do not wipe the whole workspace root unless explicitly asked.

## CLI View

There is a local alias in `/home/orangekid/.bashrc`:

```bash
agents
```

It stops the systemd service and runs Symphony in the foreground using the same env file and workflow.

Use this when the user wants to watch the terminal UI directly. Restart the systemd service afterward if they want it hosted again.

## Second Linux User: `applekid`

The user asked about using a second Linux account named `applekid`.

Do not share `/home/orangekid/.config/gh`, `/home/orangekid/.config/symphony-dashboard.env`, or other secrets directly. Set up that Linux user independently:

```bash
sudo -iu applekid
mkdir -p ~/github ~/code ~/.config
cd ~/github
git clone git@github.com:its-everdred/symphony.git
cd symphony/elixir
mise install
pnpm install
mise exec -- mix deps.get
mise exec -- mix escript.build
```

Create that user's env:

```bash
nano ~/.config/symphony-dashboard.env
```

Set the same variable names with that user's own secrets:

```bash
SYMPHONY_BASIC_AUTH_USERNAME=...
SYMPHONY_BASIC_AUTH_PASSWORD=...
GITHUB_TOKEN=...
```

Authenticate GitHub for that user:

```bash
gh auth login -h github.com
gh auth status
```

Install a user service for `applekid` using `/home/applekid/...` paths. Only one service can bind `100.81.109.51:4000` at a time. If both Linux users need concurrent instances, use a different port/hostname for one of them.

## Local Ignored Notes

This repo ignores:

```text
AGENTS.local.md
```

On this machine that file contains local runbook notes with paths and operational reminders. It is intentionally not tracked.

## Suggested Next Actions

1. Fix GitHub token/auth for the intended account.
2. Run `gh auth status`.
3. Rebuild Symphony if code changed:

   ```bash
   cd /home/orangekid/github/symphony/elixir
   mise exec -- mix escript.build
   ```

4. Start service:

   ```bash
   systemctl --user start symphony
   ```

5. Open `http://agents.amicooked.chat:4000`.
6. Label a GitHub issue with `agent:todo`.
7. Watch dashboard rows and click a running row to inspect the log modal.
8. If the issue thrashes, inspect `/home/orangekid/code/symphony-workspaces/<issue>/logs/agent.md` and system logs.
