---
ticket_id: MP-N2-C4-T02
feature_id: MP-N2
chunk_id: MP-N2-C4
bucket: 3-mobile-watch
title: "Launcher lifecycle: `aiur mobile gateway start|stop|status`, pid file, best-effort auto-start at instance launch"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C4-T01, MP-N2-C3-T02]
prior_units: [U1, U9]
prior_boundaries: [CLI]
prior_features: []
prior_findings: [OQ-N2-2]
size_owner: "aiur-engine.sh (shared with U1/U9; recheck line numbers at the implementation SHA)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C4-T02 — Gateway lifecycle in the launcher

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C4.
- **User value:** the operator never has to think about the gateway: launching any instance with mobile
  enabled starts it (OQ-N2-2, recommended yes), and explicit commands exist for control and diagnosis.
- **Deliverable (engine):**
  - `aiur mobile gateway start`: if the gateway node is up, print "already running" (exit 0); else
    launch `"$vsn_dir/elixir" --cookie … --name "aiur-${USER}-machine@127.0.0.1" --erl "-hidden"
    --boot start_clean … --eval "Aiur.CLI.main(Aiur.CLI.argv_from_file())"` with argv
    `__machine-gateway`, detached with `setsid` and `nohup`, stdout/stderr to
    `$AIUR_BG_STATE_DIR/machine/gateway.log`; wait up to 10 s for `/healthz` on `gateway.host:port`.
  - `aiur mobile gateway stop`: RPC `:init.stop()` to the gateway node with the existing watchdog
    timeout; on timeout, TERM then KILL the pid from `gateway.pid` **only if** that pid's command line
    contains `aiur-${USER}-machine` (no blind kill).
  - `aiur mobile gateway status [--json]`: `{state: running|stopped|unknown, pid, node, started_at, age_ms, listen}`.
  - Auto-start: in the instance launch path, after the instance node is up, if `~/.aiur/machine` has
    `mobile.enabled: true` and the gateway node is down, run `gateway start` in the background; any
    failure prints one warning line and never fails the instance launch.
  - Docs for optional systemd user unit / launchd agent (documented, not installed — plan §3A).
- **Non-goals:** the gateway's internals (T01), restart-on-crash supervision (the operator's unit file does that if wanted).

## Dependencies and blockers

DESIGN-N2 (Q2 auto-start — the recommendation is implemented behind the owner's answer; if the owner
answers no, drop the auto-start step and its test). MP-N2-C4-T01, MP-N2-C3-T02. Dependents: MP-N2-C3-T03, MP-N2-C9.

## Verified starting point (base `45a290e3`)

- Release launch command shape: `build_release_cmd` (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:421-431`).
- Cookie: `ensure_erlang_cookie` (`:321-347`), one per-user cookie shared by every node, so the gateway can
  `:erpc` instances (T04).
- Node liveness: `probe_named_node_liveness` (`:2166-2172`) over `probe_node_liveness` (`:2136-2149`).
- RPC with watchdog and process-group kill: `run_release_rpc_with_timeout` (`:2333-2387`).
- `warn_other_aiur_daemons` scans `pgrep`/`ss` for sibling daemons (`:3511-3530`); it must not
  report the gateway as a stray daemon — add the gateway node name to its skip list.
- Engine memory note: `pkill -f` patterns can kill the caller's own shell (operator memory
  "pgrep self-match / exit 144"); the stop path therefore uses the pid file plus a command-line check,
  never `pkill -f`.

## Chosen design

- Gateway node name fixed: `aiur-${USER}-machine@127.0.0.1`; `ERL_EPMD_ADDRESS=127.0.0.1` as for instances
  (`Aiur.Distribution` requires loopback epmd, `src/lib/aiur/distribution.ex:10-12`).
- Start is idempotent and serialized with a launch lock at `$AIUR_BG_STATE_DIR/locks/machine-gateway.launch`
  using `acquire_aiur_launch_lock` (`:1522-1563`).
- Auto-start insertion point: after the instance's distribution is confirmed up in `dispatch_run` (exact line
  chosen at implementation; recheck after U1/U9). Runs `cmd_mobile_gateway_start --quiet &`.
- `aiurdev` and `aiur` share all of this through the engine.

## Implementation steps

1. Engine functions `cmd_mobile_gateway_{start,stop,status}` and the auto-start hook (≈140 lines).
2. `warn_other_aiur_daemons` skip entry. 3. Tests. 4. Docs.

## Non-happy paths

| Case | Result |
|---|---|
| Mobile disabled | `start` exits 10 (from T01) with the enable hint; auto-start does nothing. |
| `/healthz` not reachable in 10 s | `start` prints the last 20 lines of `gateway.log` and exits 1; the node is stopped. |
| Stale `gateway.pid` (pid reused) | command-line check fails → treated as stopped; the file is removed. |
| epmd unreachable | `status` reports `unknown`; `start` refuses (cannot prove absence). |
| Two instances launch at once | the launch lock lets one start the gateway; the other sees it running. |

## Compatibility and rollout

Instances launched with mobile disabled behave exactly as before (test 5). Rollback: `aiur mobile disable` + `gateway stop`.

## Verification

`src/test/aiur_engine_mobile_gateway_test.exs` (shell-level with a fake `elixir` and fake `epmd`, the
approach of `src/test/aiur_engine_stop_pidfile_test.exs`):

1. `"start launches a hidden node named aiur-$USER-machine"` — the fake `elixir` records argv; assert
   `--name aiur-<user>-machine@127.0.0.1` and `-hidden`. *Fails without:* the `-hidden` flag (mutation: drop it → fails).
2. `"start is a no-op when the node is up"`.
3. `"stop never kills a pid whose command line lacks the gateway node name"`. *Fails without:* the check.
4. `"status is unknown when epmd is unreachable"`.
5. `"instance launch with mobile disabled never starts the gateway"`; 6. `"… with mobile enabled starts it once and a failure does not fail the launch"`.
7. `"warn_other_aiur_daemons does not report the gateway"`.

Live check (Executor, not CI): from `/tmp`, `scripts/aiurdev mobile gateway start`, then `epmd -names`,
`ps` shows no orchestrator, `aiurdev mobile gateway status --json`, `aiurdev mobile gateway stop`.

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur_engine_mobile_gateway_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation for 1, 3 recorded.
- [ ] Docs: `website/docs-app/reference/cli.md` `aiur mobile gateway start|stop|status`; the pairing guide
      (MP-N2-C9-T01) includes the optional systemd user unit and launchd agent examples.
- [ ] Dependents: MP-N2-C3-T03, MP-N2-C9-T02.
