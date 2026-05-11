# Symphony Local Handoff

This branch exists to hand the local Symphony setup to the next agent/operator.

Do not commit secrets. The machine-local secrets live outside this repo.
This is an operational handoff, not a portable setup guide. Portable workflow examples live under
`elixir/examples/workflows/`; checked-in local operational templates live under
`elixir/local-workflows/`.

## Repository State

- Current repo: `/home/applekid/github/its-applekid/symphony`
- Previous `orangekid` repo: `/home/orangekid/github/symphony`
- Remote fork: `git@github.com:its-everdred/symphony.git`
- Upstream: `https://github.com/openai/symphony.git`
- Current active branch for CLI interaction work: `symphony/original-cli-selection`
- ExRatatui spike branch pushed to origin: `symphony/interactive-cli-brainstorm`
- Older durable branch with this document: `handoff`
- `main` has already been fast-forwarded and pushed with the dashboard/log work.

## Current CLI Interaction Work

The current work is moving interactive CLI behavior back onto the original terminal renderer because the ExRatatui spike rendered incorrectly in the user's Termius SSH session.

User requirement:

- old/stable CLI renderer stays available and is the base for `agents`
- `agents` should become interactive without changing the dashboard-style output
- first interaction slice: select agents with `j/k` and arrow up/down
- later slices: right/enter opens the selected agent's logs, left/esc returns, then pause/message/split-pane controls

Current branch:

```text
symphony/original-cli-selection
```

Committed on this branch:

```text
4dc6787 Add original CLI selection
```

That commit:

- adds `--interactive` to the Elixir CLI
- makes `scripts/agents` pass `--interactive` for foreground runs
- adds `SymphonyElixir.TerminalInput`
- starts terminal input only when `:interactive_cli` is enabled
- keeps the existing `StatusDashboard` renderer
- adds a selected-agent marker (`▶`) while preserving regular status dots (`●`)
- supports `j`, `k`, up arrow, down arrow, `q`, and Ctrl-C
- changes test workflow temp directories to `/tmp/symphony-elixir-tests-<user>/workflow-*` so tests do not collide with stale `/tmp/symphony-elixir-workflow-*` directories owned by `nobody`

Validation after `4dc6787`:

```bash
cd /home/applekid/github/its-applekid/symphony/elixir
/home/applekid/.local/bin/mise exec -- mix compile
/home/applekid/.local/bin/mise exec -- mix lint
/home/applekid/.local/bin/mise exec -- mix test
/home/applekid/.local/bin/mise exec -- mix build
```

Result at that point:

- `mix compile`: pass
- `mix lint`: pass
- `mix test`: 267 tests, 0 failures, 2 skipped
- `mix build`: generated `elixir/bin/symphony`
- direct TTY smoke with `--interactive --port 0` rendered with the original CLI path and did not stair-step

User then tested in Termius and reported:

```text
arrows just type [[A chars that get deleted on the next instant re-render. no selection emoji changes
```

Interpretation:

- rendering is okay on the original CLI path
- keyboard input is not being captured from the controlling terminal
- escape bytes are echoing into the terminal instead of reaching the input loop
- selection marker not changing confirms dashboard casts are not being delivered

First attempt (`stty raw -echo < /dev/tty` via `System.cmd`) failed in Termius. The disk log captured:

```text
warning: Interactive terminal input disabled: stty: 'standard input': Inappropriate ioctl for device
```

Root cause: `System.cmd` opens the child with `:use_stdio`, so the child's fd 0 is a pipe back to BEAM. The shell does run `< /dev/tty`, but in this port context stty's redirected fd was not seen as a real tty, so `enter_raw_mode` returned `:error` and `TerminalInput` returned `:ignore`. With no reader running, arrow bytes were echoed by the user's cooked terminal driver and the dashboard repainted over them.

Working fix shipped:

- `elixir/lib/symphony_elixir/terminal_input.ex`
- `elixir/test/symphony_elixir/terminal_input_test.exs`

The fix:

- runs `stty raw -echo` and `stty sane` via `Port.open({:spawn, cmd}, [:exit_status, :nouse_stdio])` so the child inherits BEAM's real fds 0/1/2 instead of pipes — stty operates on the actual controlling terminal
- opens `/dev/tty` with `:file.open(~c"/dev/tty", [:read, :raw, :binary])` and reads with `:file.read/2` so the reader bypasses Erlang's IO server and gets byte-by-byte input
- stores `restore_terminal?` in state so the terminate callback only runs `stty sane` when init actually entered raw mode (keeps the test suite quiet)
- keeps the injectable `input_fun` and `skip_raw_mode` options used by the focused test
- keeps the test proving arrow escape sequences dispatch `{:select_agent, 1}` and `{:select_agent, -1}` casts

Confirmed in a real PTY (`script -e -c`) before commit:

- `Port.open({:spawn, "stty raw -echo"}, [:exit_status, :nouse_stdio])` → `{:exit_status, 0}`
- `Port.open({:spawn, "stty sane"}, [:exit_status, :nouse_stdio])` → `{:exit_status, 0}`
- `:file.open(~c"/dev/tty", [:read, :raw, :binary])` → `{:ok, fd}`

Validation after the fix:

```bash
cd /home/applekid/github/its-applekid/symphony/elixir
/home/applekid/.local/bin/mise exec -- mix compile
/home/applekid/.local/bin/mise exec -- mix lint
/home/applekid/.local/bin/mise exec -- mix test
/home/applekid/.local/bin/mise exec -- mix build
```

Result:

- `mix compile`: pass, no warnings (modulo the latin1 locale notice from the host)
- `mix lint`: pass
- `mix test`: 268 tests, 0 failures, 2 skipped
- `mix build`: regenerated `elixir/bin/symphony`

Next agent should:

1. In a real Termius shell, run:

   ```bash
   agents
   ```

   Then confirm:

   - pressing up/down does not echo `[[A`, `[[B`, `[A`, or `[B`
   - `j/k` changes the selected row marker
   - arrow up/down changes the selected row marker
   - `q` exits and restores terminal echo
   - Ctrl-C exits and restores terminal echo

2. If the Termius shell is left in raw/no-echo mode, recover with:

   ```bash
   stty sane
   ```

3. If Termius confirms it works, move on to the next interaction slice from the user requirement (right/enter opens the selected agent's logs, left/esc returns, then pause/message/split-pane controls).

4. If Termius still fails, check `elixir/log/symphony.log.1` for the warning text. If stty exits non-zero under `:nouse_stdio` too, the next step is to ship a small port-driver / NIF that calls `tcsetattr` on `/dev/tty` directly, instead of shelling out to `stty`.

Do not merge the ExRatatui spike branch unless explicitly asked. It is preserved for reference only.

Important local branch history now merged into `main`:

- GitHub Issues tracker config now preserved in `elixir/local-workflows/WORKFLOW.actions.local.md`
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

The local service currently runs Codex using `elixir/local-workflows/WORKFLOW.actions.local.md`. To
use Claude instead, wire Symphony's agent command to the `symphony-claude` app server once the
Claude adapter path is selected and tested.

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
cd /home/applekid/github/its-applekid/symphony/elixir
/home/applekid/.local/bin/mise install
pnpm install
/home/applekid/.local/bin/mise exec -- mix deps.get
/home/applekid/.local/bin/mise exec -- mix escript.build
```

Focused validation used during this work:

```bash
cd /home/applekid/github/its-applekid/symphony/elixir
/home/applekid/.local/bin/mise exec -- mix test test/symphony_elixir/extensions_test.exs
/home/applekid/.local/bin/mise exec -- mix format --check-formatted lib/symphony_elixir_web/live/dashboard_live.ex priv/static/dashboard.css test/symphony_elixir/extensions_test.exs
/home/applekid/.local/bin/mise exec -- mix escript.build
```

Note: full format checking previously found pre-existing unrelated formatting drift in other files. Do not conflate that with the dashboard work unless you choose to clean it deliberately.

## Local Service

The active user service for `applekid` is:

```text
/home/applekid/.config/systemd/user/symphony.service
```

Current shape:

```ini
[Unit]
Description=Symphony

[Service]
WorkingDirectory=/home/applekid/github/its-applekid/symphony/elixir
EnvironmentFile=/home/applekid/.config/symphony-dashboard.env
ExecStart=/home/applekid/.local/bin/mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails /home/applekid/github/its-applekid/symphony/elixir/local-workflows/WORKFLOW.actions.local.md
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
cd /home/applekid/github/its-applekid/symphony/elixir
/home/applekid/.local/bin/mise exec -- mix escript.build
systemctl --user restart symphony
```

At handoff time the service is inactive and disabled. It was started for testing and then stopped after issue `#2` exposed stale workspace / Git bootstrap problems.

## Dashboard

Configured in `elixir/local-workflows/WORKFLOW.actions.local.md`:

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
- Basic Auth values live in `/home/applekid/.config/symphony-dashboard.env`.
- Do not print or commit the username/password or token.

If using curl for debugging, use environment variable names only and avoid showing expanded values in logs or chat.

## Machine-Local Env

Env file:

```text
/home/applekid/.config/symphony-dashboard.env
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
/home/applekid/github/its-applekid/symphony/elixir/local-workflows/WORKFLOW.actions.local.md
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
- clone `https://github.com/its-applekid/actions.git`
- add upstream `https://github.com/ethereum-optimism/actions.git`
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
- It was blocked first by invalid GitHub auth, then by SSH Git auth for `git@github.com`.
- The service env `GITHUB_TOKEN` was refreshed from the working `gh` keyring without printing the token.
- `gh auth setup-git -h github.com` was run for `applekid`.
- `elixir/local-workflows/WORKFLOW.actions.local.md` was changed to use HTTPS remotes for the
  `its-applekid/actions` fork and `ethereum-optimism/actions` upstream.
- The HTTPS bootstrap was manually verified in `/tmp`: clone, add upstream, fetch `upstream/main`, create a `symphony/...` branch from `origin/main`, and merge `upstream/main`.
- Issue `#2` later progressed past the Git bootstrap and `.git/FETCH_HEAD` read-only problem by using the prepared `.git-writable` metadata copy.
- Current operator instruction: if issue `#2` is still making progress, do not restart Symphony or clear its workspace until the ticket finishes.

## GitHub Auth

There are two auth paths:

1. `GITHUB_TOKEN` in `/home/applekid/.config/symphony-dashboard.env`
2. `gh` auth state in `/home/applekid/.config/gh/hosts.yml`

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

Current `applekid` auth status:

- the user's interactive shell reports `gh auth status` logged in as `its-applekid` using keyring auth
- `gh api repos/its-applekid/actions --jq '.full_name'` succeeds and returns `its-applekid/actions`
- `GITHUB_TOKEN` is present in `/home/applekid/.config/symphony-dashboard.env`; Symphony's GitHub tracker requires it for polling GitHub issues
- the service env token was refreshed from `gh auth token` and verified with `gh auth status` using the env file; do not print the token
- `gh auth setup-git -h github.com` has been run so HTTPS Git operations can use `gh` credentials
- sandboxed `gh auth status` without the service env may still report the old `/home/applekid/.config/gh/hosts.yml` token as invalid; prefer a real user shell or the service env for final auth checks
- do not print or commit token values

## Workspaces And Logs

Workspace root:

```text
/home/applekid/code/symphony-workspaces
```

Per-issue workspace:

```text
/home/applekid/code/symphony-workspaces/<issue-number>
```

Agent log files:

```text
/home/applekid/code/symphony-workspaces/<issue-number>/logs/agent.md
/home/applekid/code/symphony-workspaces/<issue-number>/logs/agent.ndjson
```

Current issue `#2` workspace:

```text
/home/applekid/code/symphony-workspaces/2
```

If issue `#2` is still active, inspect the workpad and agent logs before taking action. Do not clear or restart the workspace while the agent is making progress.

If a run is thrashing on stale state:

```bash
systemctl --user stop symphony
rm -rf /home/applekid/code/symphony-workspaces/<issue-number>
systemctl --user start symphony
```

Only remove the specific issue workspace. Do not wipe the whole workspace root unless explicitly asked.

## Historical CLI View

There is a local alias in `/home/orangekid/.bashrc`:

```bash
agents
```

It stops the `orangekid` systemd service and runs Symphony in the foreground using that user's env file and workflow.

Use this when the user wants to watch the terminal UI directly. Restart the systemd service afterward if they want it hosted again.

## Current Applekid Setup Details

Current `applekid` setup status:

- Working repo: `/home/applekid/github/its-applekid/symphony`
- Branch: `handoff`
- `ripgrep` `15.1.0` is installed at `/home/applekid/.cargo/bin/rg`
- `mise` installed at `/home/applekid/.local/bin/mise`
- `elixir/mise.toml` trusted for this user
- Erlang/OTP `28` and Elixir `1.19.5-otp-28` installed via `mise`
- `mise exec -- mix setup` completed
- `mise exec -- mix build` completed and generated `elixir/bin/symphony`
- `mix deps` reports all Elixir dependencies as `ok`
- No `sudo apt` package was required for the Symphony build; optional Erlang Java/wx/OpenGL warnings can be ignored for this service

Compound Engineering setup is complete for this repo:

- `.compound-engineering/config.local.yaml` was created for machine-local CE settings
- `.compound-engineering/config.local.example.yaml` was created from the CE setup template
- `.gitignore` now ignores `.compound-engineering/*.local.yaml` instead of the whole `.compound-engineering/` directory so the example config can be committed
- `agent-browser` `0.27.0` is installed with Chrome `148.0.7778.97`
- `vhs` `0.11.0` is installed at `/home/applekid/go/bin/vhs` with a symlink at `/home/applekid/.local/bin/vhs`
- `silicon` `0.5.2` is installed
- `ast-grep` `0.42.1` is installed
- the `ast-grep` skill is installed at `/home/applekid/.agents/skills/ast-grep`
- the `agent-browser` skill is installed at `/home/applekid/.agents/skills/agent-browser`
- `ce-setup` health check passes: `7/7` tools and `1/1` skill

Current `applekid` service status:

- `/home/applekid/.config/systemd/user/symphony.service` is installed
- The service has been started for issue `#2` testing.
- Current operator instruction: do not restart Symphony while issue `#2` is making progress.
- Dashboard and workflow source changes in this branch will require rebuild/restart before they affect the running service, but defer that restart until the active ticket is finished.

Current `applekid` workflow notes:

- `elixir/local-workflows/WORKFLOW.actions.local.md` is configured for the GitHub tracker and
  `its-applekid/actions`.
- GitHub tracker states must use label slugs (`todo`, `in-progress`, `human-review`, `rework`, `merging`, `done`). The tracker emits `agent:in-progress` as `in-progress`; using display names like `In Progress` makes Symphony treat the issue as non-active and stop the worker.
- The Codex turn sandbox now explicitly includes `networkAccess: true`, because GitHub CLI and Git commands need network access inside Codex command executions.
- The workflow contains both an `after_create` bootstrap and a guarded `before_run` bootstrap. The `before_run` hook clears the issue workspace if it is not a valid Git worktree, then reclones with HTTPS.
- SSH remotes failed under the service with `git@github.com: Permission denied (publickey)`. Keep HTTPS remotes unless SSH auth is deliberately configured for the `applekid` service environment.
- The workflow now tells agents resuming an already-active issue to first read the `## Codex Workpad`, `logs/agent.md`, `logs/agent.ndjson` when needed, and current Git state before changing code. This is meant to preserve progress across restarts and avoid repeating completed work.
- After editing workflow config only, restart the service. After changing Elixir source, rebuild `elixir/bin/symphony` with `/home/applekid/.local/bin/mise exec -- mix escript.build` before restarting.

## Historical First User: `orangekid`

The earlier local setup was under Linux account `orangekid`. Keep this only as historical context or a fallback reference.

Do not share `/home/orangekid/.config/gh`, `/home/orangekid/.config/symphony-dashboard.env`, or other secrets directly. If returning to that user, validate its setup independently:

```bash
sudo -iu orangekid
cd /home/orangekid/github/symphony/elixir
mise exec -- mix escript.build
systemctl --user status symphony
```

Known `orangekid` paths from the previous handoff:

- repo: `/home/orangekid/github/symphony`
- service: `/home/orangekid/.config/systemd/user/symphony.service`
- env: `/home/orangekid/.config/symphony-dashboard.env`
- workspace root: `/home/orangekid/code/symphony-workspaces`
- sibling Claude app server: `/home/orangekid/github/symphony-claude`

Only one service can bind `100.81.109.51:4000` at a time. If both Linux users need concurrent instances, use a different port/hostname for one of them.

## Local Ignored Notes

This repo ignores:

```text
AGENTS.local.md
.compound-engineering/*.local.yaml
```

On this machine `AGENTS.local.md` contains local runbook notes with paths and operational reminders. It is intentionally not tracked. `.compound-engineering/config.local.yaml` contains machine-local Compound Engineering settings and is intentionally not tracked.

## Suggested Next Actions

1. While issue `#2` is making progress, monitor without restarting:

   ```bash
   git -C /home/applekid/code/symphony-workspaces/2 status --short --branch
   tail -n 120 /home/applekid/code/symphony-workspaces/2/logs/agent.md
   ```

   A healthy run should show a real Git checkout on a `symphony/...` branch and recent agent log events.

2. After issue `#2` finishes, rebuild Symphony so dashboard and workflow source changes are picked up:

   ```bash
   cd /home/applekid/github/its-applekid/symphony/elixir
   /home/applekid/.local/bin/mise exec -- mix escript.build
   ```

3. Restart the user service only after the active ticket is done:

   ```bash
   systemctl --user restart symphony
   ```

4. Open `http://agents.amicooked.chat:4000`.
5. If an issue thrashes, inspect `/home/applekid/code/symphony-workspaces/<issue>/logs/agent.md` if it exists, inspect the `## Codex Workpad`, and inspect `journalctl --user -u symphony -n 200 --no-pager`.
