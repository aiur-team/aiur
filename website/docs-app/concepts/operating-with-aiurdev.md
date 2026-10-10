# Operating with `aiurdev`

`scripts/aiurdev` is a thin dev shim: it rebuilds the local release when sources change (running `mix deps.get`, `mix compile`, and `mix release --overwrite` on a fresh clone), then execs the shared launcher engine (`packaging/npm/aiur-cli/libexec/aiur-engine.sh`) against `src/_build/dev/rel/aiur`.

The npm-installed `aiur` runs the same engine against the platform release, so every command below works identically under `aiur`.

After `mise run setup`, `aiurdev` is on your `PATH`:

| Command | What it does |
|---|---|
| `aiurdev` | Start the workflow in the foreground, or attach to this directory's live interactive session |
| `aiurdev <config-path>` | Run an explicit YAML config in the foreground |
| `aiurdev --test` | Reset the first pinned sandbox ticket, then start an interactive smoke run |
| `aiurdev --test3` | Reset the pinned 3-ticket blocker-chain sandbox, then start an interactive smoke run |
| `aiurdev --bg` | Start a detached headless BEAM with the web dashboard enabled |
| `aiurdev --bg --no-dashboard` | Start a lean detached headless BEAM without the web dashboard |
| `aiurdev --no-dashboard` | Start the foreground terminal UI without the web dashboard |
| `aiurdev stop` | Stop the running session (BEAM + tmux) |
| `aiurdev restart [--no-build]` | Stop the session, rebuild the release when sources are newer, then start again detached; `--no-build` bounces on the release already on disk |
| `aiurdev status` | Show active agents and their running/paused/idle state, GitHub CI readiness, and `SUPERVISION N/N` liveness; a degraded or unavailable supervision tree returns nonzero |
| `aiurdev executor-answer <decision-id> --expected-version <n> (--option <id>\|--custom-response <text>) --rationale <text> --idempotency-key <key> [--supersede] [--executor-id <id>]` | Record a direct Command answer with an explicit Executor actor; version and idempotency fields make listener replay safe; `--supersede` replaces a decided answer that no agent has received |
| `aiurdev executor-escalate <decision-id> --expected-version <n> --reason <text> [--executor-id <id>]` | Leave a Command open and raise one keyed operator notification when Executor judgment is insufficient |
| `aiurdev executor-moot <decision-id> --expected-version <n> --reason-class <class> [--reason <text>] [--executor-id <id>]` | Retire a void Command, or withdraw a decided answer that no agent has received; a mooted answer is never delivered |
| `aiurdev units [--scope live\|unfinished\|all\|none] [--condition active\|alert\|paused\|queued\|finished]... [--format auto\|table\|records] [--json]` | Render the dashboard's Units ticket view, including its filters and source freshness; `--format` picks the human layout (`auto` uses a table only on a wide terminal); `--json` emits the stable envelope |
| `aiurdev analytics [--range run\|full] [--since <ISO-8601>] [--until <ISO-8601>] [--build-order <id>] [--json]` | Render the Analytics dashboard snapshot for an explicit chart window |
| `aiurdev pause <id...>` / `pause --all` | Cooperatively pause agents by issue ID |
| `aiurdev resume <id...>` / `resume --all` | Resume paused agents by issue ID |
| `aiurdev reset-budget <id...>` | Queue lifetime dispatch-latch resets; completion or failure is reported in alerts |
| `aiurdev --todo <id...> [--only]` | Queue GitHub tickets; with `--only`, dequeue all other pending tickets |
| `aiurdev init [--force]` | Scaffold `.aiur/config` in the current repo |
| `aiurdev build` | Force-rebuild the local release (dev shim only) |

Pure control commands (`agents`, `status`, `set`, `pause`, `resume`, `message`, `units`, and `stop`) reuse the existing dev release when it is complete, even if sources are newer. They control the already-running node, so a stale-source rebuild would not update that session. Run/start paths and explicit `aiurdev build` still rebuild when needed.

`restart` reuses the existing release for that pre-dispatch step too, but for the opposite reason: it rebuilds between its own stop and start, so rebuilding first would rewrite the release under the still-live BEAM.

`--todo` is a standalone GitHub operation and does not require a running Aiur session. It derives labels from the current config. `--only` removes the queue label from other pending tickets but leaves in-progress work untouched.

Concurrent `--only` invocations are not coordinated across processes; running two overlapping `aiurdev --todo ... --only` commands can drop each other's tickets, so avoid running them at the same time.

If a control command times out while the daemon is still live, the outcome is unknown. Check the daemon state before retrying or taking destructive action; the CLI does not infer a cause or recommend restarting the whole session.

It does print what it can observe without the daemon cooperating — the orchestrator's mailbox depth, run status and current function — because a large mailbox or a blocked current function means one process is stuck, not that the host is busy.

`resume` on a paused agent never claims an outcome it has not observed. The orchestrator answers as soon as the resume control request is queued for the agent, so the CLI then waits for that agent to actually leave the paused state before printing `aiur: resumed #44`.

Every resume in one invocation shares a single 4s confirmation budget, so `resume --all` stays inside the control-RPC timeout. A worker refusal is reported as `declined` with the held pause condition; a lifecycle expiry is reported as `dropped` with its reason.

If the request is still pending at the confirmation deadline, or the correlated outcome cannot be determined, the CLI says the outcome is unknown. Every unapplied path exits 1, and the same declined/dropped reason remains visible on the dashboard's paused row.

Read-only fleet queries never use an empty buffer to mean success: `status`, `agents`, and `watch` print an affirmative empty-fleet row when no agents are active. Query failures print one stderr diagnostic and exit 1.

Bounded query timeouts name their budget, report that the outcome is unknown, and print the observed orchestrator mailbox and current function rather than guessing a cause, and exit 124; any partial fleet output captured before an outer RPC timeout is discarded rather than presented as a trustworthy snapshot.

Pause and resume target issue IDs, not process IDs. Space-separated and
comma-separated forms are both accepted:

```bash
aiurdev pause 44
aiurdev pause 44 45 46
aiurdev pause 44,45,46
aiurdev resume 44
aiurdev status
```

Pause is cooperative: the running agent receives the same pause request used by the
dashboard and agent-list pane, then stops at its next safe turn boundary. Pausing an
already-paused agent is a no-op and exits successfully.

For tracker-level shelving, apply `agent:paused` in GitHub instead of changing
the issue state. Aiur will not claim a paused `agent:todo` ticket, will
cooperatively pause a running ticket when the label appears, and `aiurdev watch`
shows the override as `paused`.

`aiurdev resume <id>` removes `agent:paused` from the tracker before it resumes
or starts the local agent. If the tracker refuses that removal, the command exits
non-zero and explains that the resume will not hold; it does not report a plain
success. A fleet-wide `aiurdev resume` still preserves per-ticket pause labels.

When `server.host` is absent, the dashboard binds `127.0.0.1` by default (or the `AIUR_DEFAULT_DASHBOARD_HOST` override). There is no automatic Tailscale detection — set `server.host` explicitly to serve the dashboard beyond the machine. Configured `server.host` wins over that default, and explicit `--host` wins over both.

Startup output reports the usable URL and effective bind host and port.

Background mode is headless at the terminal layer: it skips the interactive agent-list and chat/prewarm panes while serving the web dashboard at the configured host and port.

Detachment and dashboard availability are independent: add `--no-dashboard` for the lean background shape, or use `--no-dashboard` in foreground mode to keep the terminal UI without an HTTP listener. The launcher still uses one detached tmux session to own the BEAM lifetime and cleanup watchdog.

If that session is already live, `aiurdev --bg` exits successfully and prints `Attach with: aiur`; a bare `aiurdev` or `aiur` from the same project directory attaches when the live run has an interactive terminal stack. Plain `--bg` is headless, so use `--bg --interactive` when a detached run should remain attachable to the terminal UI.

The per-project identity keeps concurrent repositories separate. If a tmux session is stale and distribution confirms its keyed BEAM is down, the launcher cleans it up before starting a fresh background run.

Claude Remote Control lifecycle hooks post to `Aiur.HttpServer`, so a no-listener run cannot support configured Remote Control. Startup fails with a clear error when `--no-dashboard` is combined with `agent.remote_control: true` or an `agent.routing` value ending in `+remote`; remove the flag or disable that Remote Control configuration.

Runtime `model:remote` dispatch and live promotion also fail fast if no listener is actually bound. Background startup prints the confirmed bound URL or an explicit listener-unavailable warning.

Non-loopback dashboard binds retain the authentication guard: set both
`AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`, or Aiur refuses the
dashboard bind while leaving the agent runtime available.

Use `--port <N>` before the config path to override the dashboard/workflow port
for one invocation:

```bash
aiurdev --port 4099
aiurdev --port 4099 --bg
aiurdev --port 4099 --bg --no-dashboard
aiurdev --port 4102 ./.aiur/config
```

The `--test` and `--test3` reset paths require their pinned sandbox issues to be open before launch. If a pinned issue is closed, reset removes any detected `agent:*` or `model:*` labels from that closed issue, skips normal dispatch labeling, and aborts with instructions to reopen the ticket or update `.aiur-test-tickets.json`.

These manual test modes are blocked inside agent issue workspaces because they mutate pinned GitHub sandbox tickets; run them from the Executor repo root or a dedicated isolated harness. Foreground startup prints the resolved tmux socket/session, which non-TTY drivers should use instead of hard-coded socket names.

### GitHub CI handoff safety

After CI passes, Aiur persists the approved PR head before handing the ticket back to its agent. A later CI observation for that exact SHA cannot return the ticket from human review to rework, even when the poll retained a stale `ci-wait` issue snapshot from before the handoff.

A CI failure for a different SHA supersedes the approval and remains eligible for the normal rework path. Check runs whose names end in `(non-blocking)` are advisory and do not affect the lifecycle decision.