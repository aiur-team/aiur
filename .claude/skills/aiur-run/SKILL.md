---
name: aiur-run
description: "Launch and babysit a background (--bg) aiur dogfood run end-to-end — pre-flight config + build + prewarm, launch detached, then monitor agents/CPU/FD/prewarm and drive pause/resume/stop. Use when asked to 'run IAR', 'run aiur', 'iarc run', 'launch aiurdev', 'start the dogfood loop', or kick agents off on the agent:todo backlog."
---

# Run aiur in --bg mode

Operator playbook for running a background aiur run myself: launch it detached, keep it
healthy, and drive the controls. Pairs with the `aiur-monitor` skill — that one owns the
per-agent status read; this one owns launch + lifecycle.

`iarc` is an operator alias for `aiur` in this repo. Treat `/iarc run` as this
same aiur background-run playbook.

## Mental model

- `scripts/aiurdev` is the dev shim: it rebuilds the local `mix release` when stale, then
  `exec`s the shared engine (`packaging/npm/aiur-cli/libexec/aiur-engine.sh`). Subcommands
  (`--bg`, `stop`, `pause`, `status`, `watch`, `message`) are passed straight through to the engine.
- `aiur --bg` runs the BEAM headless in a **detached tmux session**. Identity is
  per-instance-keyed (#431): node/tmux/socket are keyed by the repo root, so a second aiur
  from a different root coexists instead of reaping this one.
- The orchestrator dispatches agents for tickets matching the `agent:` label prefix + the
  tracker's active states (`.aiur/config`). `complexity:N` routes the backend (4–5 → claude).
- **Prewarm** (the CPU-saver): one shared base of latest main is built+compiled at
  `~/.aiur/repo/<owner>/<name>`, and each agent workspace is materialized from it via
  copy-on-write — no per-agent cold clone+build. The eager gate **holds dispatch until the
  base is `:ready`**, so agents wait for the warm base rather than 10× cold-cloning.

## 1. Pre-flight

1. **No nested tmux** — aiurdev refuses if `$TMUX` is set. Run from a bare terminal.
2. **Pull main** — `git -C <repo> pull origin main` so the build + prewarm base carry the
   latest merged fixes.
3. **Check for a live instance** — `pgrep -f 'rel/aiur/.*beam'`. For the operator's own run,
   stop a stale one first: `aiurdev stop`.
4. **Set concurrency in `.aiur/config`** (no `--max-agents` flag yet — see #449):
   - `agent.max_concurrent_agents` — the ceiling (operator default ≤ 10).
   - `pre_warmed_sessions` — the warm-pool / first-open latency dial. It controls how many
     opencode serves boot eagerly at startup, not how many agents can run. Keep it at the
     number of instant-open chat panes you actually want; cold slots grow on demand up to the
     larger of the pane-grid capacity and `agent.max_concurrent_agents`.
   - Never `aiurdev init --force` — it clobbers `.aiur/config`.
5. **Backlog ready** — `gh issue list --label agent:todo --state open` should be non-empty.

## 2. Build the latest release

`cd <repo> && aiurdev build` force-rebuilds the release from the working tree
(`aiurdev build --deps` wipes `_build/dev` for a clean dep rebuild). A bare `aiurdev` only
rebuilds when stale.

## 3. Launch (detached, logged)

Run it backgrounded and **always pass `--debug`** — the verbose logs under `~/.aiur/logs` are how
you monitor agents and diagnose snags (firehose/token failures, workspace-hook errors, stalls):

```
aiurdev --bg --debug    # --debug = AIUR_DEBUG=1 (verbose); logs land under ~/.aiur/logs
```

Never use `--test` / `--test3` for a real run — those reset the sandbox tickets.

## 4. Verify prewarm (do this every launch)

The base builds/refreshes via `Aiur.RepoBase` on first dispatch, held by the eager gate.
Confirm it actually worked:

- Base current: `~/.aiur/repo/<owner>/<name>/.aiur-base-built` exists with `_build` + `deps`.
- Log reaches `prewarm:phase … :ready` — `grep -i prewarm <log>`. A failure logs
  `prewarm base unavailable: …` loudly (#441).
- Workspaces appear quickly under `workspace.root` (CoW materialize), not after a per-agent
  build. If agents are each cold-cloning/building → prewarm is broken; stop and fix before
  10 concurrent builds melt the box.

## 5. Monitor — REQUIRED: ASK the cadence, then arm it immediately on launch

**REQUIRED SUB-SKILL: `aiur-monitor`.** Launch is not "done" when the BEAM is up — it's done
when the status cadence is running. **Arming the recurring timer is part of "launch is not done":
an un-armed cadence (relying on event/completion notifications instead of an armed `/loop` or
equivalent recurring wake) is a failed launch** — see `aiur-monitor`'s "How to enforce the cadence."

**REQUIRED pre-flight/launch step — ASK the cadence once.** Before (or at) launch, **ASK the
operator their preferred status-table update cadence** — use **AskUserQuestion**, offer 5 / 10 /
15 min, and **default to 5 minutes** if they don't specify. **Record the chosen interval for the
whole session**; that single answer drives the auto-cadence and you never re-ask it.

Immediately after a verified launch (step 4 confirms prewarm), you **MUST** hand off to
`aiur-monitor` and start its **auto-cadence at the operator's chosen interval**: post a fresh
board (run `aiurdev watch`) every `<chosen>` minutes (the `/loop <chosen>m` interval;
"approximately" is not license to stretch it past the chosen interval), automatically, until the
run reaches a terminal state or the operator says stop. This is not optional and the operator
should **NEVER** have to ask for the next update — see `aiur-monitor`'s "Monitoring cadence" for
the required rule, the board format, and the alert relay. (5 min is the recommended default; the
operator picks the value once via the ask above.)

- **Agents** — start the cadence now by arming the loop at the chosen interval:
  `/loop <chosen>m /aiur-monitor` (e.g. `/loop 5m /aiur-monitor` for the default). There is no
  self-ticking fallback — if you do not arm `/loop`, no further updates will fire, which is the
  failure this step exists to prevent. Don't skip a tick when nothing changed — post the board
  anyway, noting steady-state (`aiurdev watch --changes` prints `(no changes)` — relay that).
- **Alerts** — arm `aiur-monitor`'s real-time alert relay now: start `watch-alerts.sh` once via the **Monitor tool** (`persistent: true`) and post every new alert in chat (`#<ticket> · <name> · <reason>`), so the operator gets the "why" the instant the chime plays. `aiurdev watch`'s `ACTIONABLE` section is the periodic floor (+ PushNotification for new needs-attention alerts). See `aiur-monitor`'s "Real-time alert relay".
- **CPU/FD** — watch `top`/`ps` for CPU; `grep -i emfile <log>` (#409 — FD exhaustion at high
  concurrency). If CPU pegs or `:emfile` appears → lower `pre_warmed_sessions` /
  `max_concurrent_agents` and relaunch.
- **Stuck agents** — repeated "Operator check-in" with no progress, or broken progress bars →
  investigate; file `agent:todo` or grab it.

## 6. Controls

- **Pause / resume** (to work agents between other tasks): `aiurdev pause --all` /
  `aiurdev resume --all`. (#438: a masked rpc error can read as "no running node" — cross-check
  with `aiurdev status`.)
- **Status** — `aiurdev status`.
- **Message an agent** — `aiurdev message …`.
- **Stop** — `aiurdev stop` reaps the BEAM, tmux session, and agent sockets.

## 7. Review + merge agent PRs

As agents open PRs, review green/red (or `/code-review`), merge the good ones, and route any
issues found as `agent:todo` (preferred) or self-fix via the CE loop when not agent-safe.

## Known issues to watch

- **#409** — OS-process/FD footprint / `:emfile` at high concurrency. Keep concurrency in check.
- **#438** — control rpc masks real errors as "no running node." Verify with `status`.
- **#449** — `--bg` boots UI-only work (panes, dashboard, chat backfill) and lacks a
  `--max-agents` flag + a built-in status command. Until then, set agents via config and use
  `aiur-monitor`.
