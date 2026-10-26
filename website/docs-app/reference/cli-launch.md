---
pageClass: cli-reference
---
# CLI launch and setup

Local `aiur`/`aiurdev` use `~/.aiur/config`; global launches announce config and `origin` and ensure workflow/marker and complexity labels; `aiur init` provisions `flake` for [CI failure evidence](/apis/ci-failure-evidence); `aiur` lets an agent operate the run while humans type commands or watch the TUI/dashboard.

| Design goal | Result |
| --- | --- |
| Executor access | An agent can operate a run from a terminal without asking a human to type commands. |
| Surface parity | The CLI targets feature parity with the [GUI](/guide/gui) and [TUI](/guide/tui). |

Global launches require Issues write access; conflicting repos fail. Omit `tracker.github.repo` for portable settings; exported credentials override `.env`. Run the command from the repository that owns the run. An instance is keyed to that project, so control commands without `--instance` address that repository's daemon.

## What the CLI does
| Job | Commands | Notes |
| --- | --- | --- |
| Start or attach | `aiur`, `aiur run` | Bare `aiur` attaches to this repository's live session when one exists; otherwise foreground gives the TUI board and chat panes. Background is headless unless launched with `--interactive`. |
| Inspect live state | `status`, `agents`, `watch`, `alerts`, `usage` | Read-only reports from the running daemon. |
| Operate the fleet | `set`, `pause`, `resume`, `park`, `take`, `release`, `message`, `reset-budget`, `workspace-recover`, `stop`, `restart` | Steers a live run, manages persistent runtime settings, assigns Executor-owned tickets, recovers identified workspace holds, and manages paused reservations. |
| Mirror a dashboard page | `units`, `commands`, `build-orders`, `queue show`, `analytics` | Read-only terminal forms of dashboard data; `build-orders` and `queue show` read the Build Order and queue projections. |
| Act on durable records | `ask`, `asks`, `executor-answer`, `operator-relay-answer`, `executor-escalate`, `executor-reclassify`, `executor-moot`, `executor-emit`, `listen`, `findings`, `feature`, `epic`, `ticket estimate` | Decision inbox, Executor actions, and findings ledger. |

Background mode is the shape that matters for an agent Executor. `aiur --bg` starts the daemon with no board and no panes, the dashboard stays up, and every command below reads and writes the same live state through that detached daemon.

## Start, initialize, and queue
See [global launch options](/reference/cli-options) for parser flags and launcher-only options.

### Commands
| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur` | Attaches to this repository's live tmux session when one exists; otherwise starts a foreground interactive run. Attachment does not create a second run or take teardown ownership, so detaching leaves the daemon healthy. | `aiur` |
| `aiur --instance <name\|all> <command>` | Runs a supported control command against one named remote daemon, or uses `all` to run a read command against every registered instance in parallel. Each instance stays labeled, including unreachable failures; `--json` emits one envelope per instance. `--instance` must be the first argument; see [remote instances](/reference/cli-options#remote-instances). | `aiur --instance all agents` |
| `aiur init` | Interactive setup detects the tracker and toolchain, writes `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`, `.aiur/alerts`, and prewarm support when selected, then creates the repository state-node tree and warms the base build. For GitHub trackers it verifies repository access before offering CI and label setup, with token-specific recovery guidance when an organization-owned repository is hidden by GitHub's authorization-masked 404; Local setup asks once whether to use an App for the daemon and defaults to No (`GITHUB_TOKEN`); hosted/container setup prints the App permissions and webhook events and selects App auth by default. `AIUR_GITHUB_ALLOW_PAT=1` explicitly opts into a PAT. Choosing App points to the existing App setup guide. It also asks whether to enable Stream Deck voice input with ElevenLabs speech-to-text; answering yes writes the `elevenlabs` section, defaulting the key to the `$ELEVENLABS_API_KEY` environment reference. When the repository has no `.aiur/config` but `~/.aiur/config` exists, it asks whether to resume the global config or create a repo-local one: repo-local is the default when the checkout's `origin` remote differs from the global config's `tracker.github.repo`, and global when they match, no repo is pinned, or no `origin` remote can be detected. For GitHub repositories, Aiur waits for required CI checks before merging agent work, so setup checks whether the repository has a pull-request workflow and required checks. A missing configured branch stops setup with guidance to update `tracker.base_branch`; access errors also stop before a lower-priority CI scaffold question. If a workflow is created, replace its failing placeholder with the real test command, require `ci / required` in GitHub Settings → Rules → Rulesets for the base branch, then rerun `aiur init`. Accepted and declined setup choices are saved; resuming setup shows those selections and skips the recorded questions, while a choice absent from older config is still offered. Claude adapter setup leaves a satisfying installed version unchanged and uses a version-safe source when installation is needed. | `aiur init` |
| `aiur init --force` | Recreates generated configuration for the location you choose at the first prompt; picking repo-local leaves an existing `~/.aiur/config` untouched. `--force` explicitly re-runs setup choices, including recorded declines. Re-running without it preserves existing scaffold files and recorded declines. | `aiur init --force` |
| `aiur login <harness> <name> [--dir <path>]` | Creates or adopts an isolated profile for Claude or Codex and starts its interactive login. API-key harnesses (`kimi`, `deepseek`, `openrouter`) require the named `*_API_KEY__<NAME>` entry in `~/.aiur/.env`; the secret is never stored in the account registry. | `aiur login codex work` |
| `aiur logout <harness> <name> [--purge]` | Removes an account from the machine registry. Its profile remains unless `--purge` is specified; `default` is protected. | `aiur logout codex work` |
| `aiur token create <name> [--scope read\|write]` | Creates a client bearer token, stores only its hash, and prints the value once. Scope defaults to `write`. | `aiur token create streamdeck --scope write` |
| `aiur token list` | Lists token names, scopes, and creation times without revealing credentials. | `aiur token list` |
| `aiur token revoke <name>` | Revokes a client token immediately. | `aiur token revoke streamdeck` |
| `aiur run [--bg] [--container]` | Foreground by default; `--bg` starts a detached headless session. `--container` runs headlessly without tmux, streams logs to stdout/stderr, and rejects `--bg`, `--interactive`, and `--no-dashboard`. It requires a cookie of at least 16 letters, digits, underscores, or hyphens via `AIUR_ERLANG_COOKIE` or an existing `AIUR_COOKIE_FILE`; it never reads `releases/COOKIE`. Pass the same `AIUR_ERLANG_COOKIE` to `docker exec aiur status` and other control commands, or mount the same `AIUR_COOKIE_FILE`. `AIUR_CONTAINER_STOP_GRACE_TICKS` sets the SIGTERM wait in 0.1-second ticks (default 300); Docker Compose should set `stop_grace_period: 65s` for shutdown and agent cleanup. | `aiur run --container` |
| `AIUR_CONTROL_RPC_TIMEOUT_SECONDS=<n> aiur --todo …` | `--todo` sizes its deadline by the request, rather than using the shared 10-second control-RPC deadline. Queue add/remove also use 15s plus 3s per ID and honor this override; their timeout leaves the outcome unknown. Its default window is 15s, plus 3s per requested ID, plus 90s when `--only` is given. The daemon self-limits 10 seconds inside that window: a run it cannot finish stops itself, names the tickets it never reached, and exits nonzero, so the outcome is always definite rather than "unknown". This variable overrides the whole window when set to a positive integer; a zero or malformed value is ignored in favor of the sizing above. | `AIUR_CONTROL_RPC_TIMEOUT_SECONDS=300 aiur --todo 142 --only` |

Background and container runs persist Logger output at `<logs-root>/log/aiur.log`; `--debug` enables debug messages. By default, `<logs-root>` is `~/.aiur/logs/<launch-id>/`; stdout/stderr is saved to `log/boot.out.log`, and container mode streams it to the platform collector.

`aiur status` shows `optimistic n/cap`, `MERGE POLICY`, watcher state (`running`, `unavailable`, `not_running`), CI SHA/age/red start date, degraded CODEOWNERS trust, empty-cycle causes/ages, and prewarm holds. Daemon-read sections share a 1.5s bound: slow sections show last good output with `STALE` age, or `unavailable` and exit 1 without a saved result.

`CI WAIT` lists tickets, PRs, recovery state (including `draft_pr`) and failing checks, including tickets without workers. `aiur capabilities` shows `ci=<mode> local_tests=<mode>` ([merge policy](/reference/merge-policy)).

The `POLL` line reports the age and freshness of the last dispatch poll attempt. A daemon that has not started a dispatch poll says so; unavailable age is never rendered as zero.

On Linux, `aiur init` probes the Codex command sandbox when Codex is selected. A failure shows the command output and offers a retry; see the [Linux setup steps](/guide/quick-start#codex-on-linux).

Event counters, subscriptions, session handles and the alert ledger survive restarts in instance- and repository-scoped runtime state. Central alert and event-publication audit logs remain per launch; `--logs-root` controls those logs.

On upgrade, session handles and subscriptions start empty once, just as they previously did on every restart; state saved from that boot onward is durable. The event counter seeds above the maximum across all launches' counters, logs, the journal and the clock; the alert ledger adopts only its exact project-scoped filename and backfill marker once.

Launch mode determines which interfaces remain available:

| Launch choice | Behavior |
| --- | --- |
| Foreground | Shows the terminal board and chat panes. A later bare `aiur` from the same repository reattaches to that session. |
| `--bg` | Runs headlessly but keeps the dashboard unless paired with `--no-dashboard`. |
| `--container` | Runs headlessly in the foreground without tmux, keeps the dashboard, streams logs to stdout/stderr, and forwards SIGTERM for graceful shutdown. Suitable as a container's main process. |
| Host precedence | `--host` wins over `server.host`, which wins over `AIUR_DEFAULT_DASHBOARD_HOST` or the `127.0.0.1` default. |
| Startup output | Reports the usable dashboard URL and effective bind host and port. |

When an unknown subcommand is routed through a release built from a checkout, Aiur also compares the dispatcher and checkout package versions. If the dispatcher is older, the error tells you to update `aiur-cli` instead of presenting the command as simply unavailable.

