---
ticket_id: MP-N2-C4-T01
feature_id: MP-N2
chunk_id: MP-N2-C4
bucket: 3-mobile-watch
title: Lean gateway boot (hidden node aiur-$USER-machine, no Aiur.Application tree) and its supervision tree — resolves RQ-N2-3
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C1-T02, MP-N2-C3-T01, MP-R1-C1-T01]
prior_units: [U9]
prior_boundaries: [CLI, WEB]
prior_features: [MP-R1]
prior_findings: [RQ-N2-3, MP-N2 F15]
size_owner: "cli.ex (U8 ledger owner; look up at the implementation SHA); new modules n/a"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C4-T01 — Lean gateway boot

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C4 "Gateway process".
- **User value:** pairing and discovery work with zero instances running and never start the
  orchestrator, tracker polling, GitHub token resolution or agents (brief N2: "do not silently require
  the entire orchestration stack just to pair or discover").
- **Deliverable:**
  - A new CLI entry `aiur __machine-gateway` (internal; launched only by MP-N2-C4-T02) that runs under
    the release's `start_clean` boot **without starting the `:aiur` application**, starts the
    dependencies it needs (`:crypto`, `:public_key`, `:ssl`, `:bandit`, `:yamerl`, `:jason`), loads
    `:aiur` application env, and starts `Aiur.Machine.Gateway.Supervisor`.
  - `Aiur.Machine.Gateway.Supervisor` (PROPOSED, `:one_for_one`) with children:
    1. `Aiur.Machine.Gateway.StoreLockHolder` — `Store.hold_lock/0` for the node's lifetime (MP-N2-C1-T02);
       exits the VM with "gateway already running (pid N)" when the lock is held by a live gateway.
    2. `Aiur.Machine.TokenVerifier` cache owner (MP-N2-C1-T03).
    3. `{Bandit, plug: Aiur.Machine.Gateway.Router, ip: gateway.host, port: gateway.port, scheme: :http}`
       — TLS options are added by MP-N2-C10-T02.
    4. `Aiur.Machine.Gateway.PidFile` — writes `<state>/machine/gateway.pid` (`"<os_pid> <node> <started_at>"`), removes it on terminate.
  - `Aiur.Machine.Gateway.Router` (Plug.Router) with only `GET /healthz` → `{"contract":"aiur.machine/v1","ok":true}`
    in this ticket; `/v1/*` routes come from C4-T03/T04 and C5.
- **Non-goals:** launcher lifecycle (T02), auth plug and signing (T03), registry API (T04), TLS (C10-T02).

## Dependencies and blockers

- DESIGN-N2 gate (no UI). MP-N2-C1-T02 (lock), MP-N2-C3-T01 (settings).
- **MP-R1-C1-T01** (component manifest): R1 must list `aiur_machine` as a component whose
  dependencies exclude orchestration (contract A1). If R1 has not landed, this ticket still uses the
  same module boundary (`src/lib/aiur/machine/`) and MP-R1's checker absorbs it later (plan §10).
- Dependents: MP-N2-C4-T02..T04, MP-N2-C5-*, MP-N2-C10-T02, MP-N3-C2.

## Verified starting point (base `45a290e3`)

- **Why the existing app cannot be reused with a flag:** `Aiur.Application.start/2`
  (`src/lib/aiur.ex:31-113`) does, before any child starts: `Aiur.Config.settings_uncached()`
  (workflow config, `:40`), `record_daemon_start/0` (`:50`), `DaemonHeartbeat.write!/0` (`:53`),
  `resolve_github_token/0` (`:58`), `AgentGitHubGuard.ensure_agent_token_file/0` (`:63`),
  `Aiur.GlobalConfigStartup.prepare/0` (`:69`) — then `child_specs/1` (`:244-…`), which has no shape
  without `Aiur.Orchestrator` (`:442`). A gateway started from an arbitrary directory must not read a
  workflow config or touch GitHub credentials. `mix.exs:147-151` makes `Aiur.Application` the only
  application callback, and the release has one app (`mix.exs:195-203`).
- **Precedent for running code without the app tree:** the engine boots the release with
  `--boot start_clean` and `--eval "Aiur.CLI.main(...)"` (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:421-431`);
  `--todo` "runs under the distribution-free start_clean boot and never starts Aiur's supervision tree"
  (`src/lib/aiur/cli.ex:100-103`). The gateway follows that path, adding `--name` and `-hidden`.
- **Why hidden:** instances register names with `:global` for the alert-ledger lock
  (`src/lib/aiur/alert_ledger.ex:354-368`). A *visible* gateway connected to two instances would make
  `:global` connect the instances to each other (full mesh) and merge their name spaces. Erlang
  `-hidden`: "Hidden nodes always establish hidden connections to all other nodes … Hidden connections
  are not published on any of the connected nodes" (<https://www.erlang.org/doc/apps/erts/erl_cmd.html>,
  OTP 29.1.1 page, accessed 2026-10-06; flag unchanged in the pinned OTP 28). Instances already see
  hidden nodes (`Aiur.Distribution` monitors `node_type: :hidden`, `src/lib/aiur/distribution.ex:46-48`),
  and the only consumer, `PaneManager`, ignores `:nodeup`/`:nodedown` (`src/lib/aiur/pane_manager.ex:398-400`).
- Node naming: instances are `aiur-$USER[-KEY]@127.0.0.1` with a 10-hex `KEY` (`aiur-engine.sh:269-294`).
  `aiur-$USER-machine` cannot collide (`machine` is not hex).
- Bandit 1.12.4 can be started directly as a child with `plug:`, `ip:`, `port:`, `scheme:`
  (<https://bandit.hexdocs.pm/1.12.4/Bandit.html>, accessed 2026-10-06).

## Chosen design (RQ-N2-3 resolution)

- **Separate entry, not a flag inside `Aiur.Application`.** `Aiur.CLI.evaluate/1` gains
  `["__machine-gateway"]` → `{:machine_gateway, opts}`; `dispatch/1` calls
  `Aiur.Machine.Gateway.Boot.run/0`:
  ```elixir
  def run do
    :ok = Application.load(:aiur)                    # env only; Aiur.Application.start/2 is NOT called
    {:ok, _} = Application.ensure_all_started([:crypto, :public_key, :ssl, :yamerl, :jason, :bandit, :plug])
    with {:ok, settings} <- Aiur.Machine.Settings.load(),
         true <- settings.mobile.enabled || {:error, :mobile_disabled},
         {:ok, _identity} <- Aiur.Machine.Store.identity(),
         {:ok, sup} <- Aiur.Machine.Gateway.Supervisor.start_link(settings) do
      wait_for_shutdown(sup)                         # same shape as Aiur.CLI.wait_for_shutdown/0
    end
  end
  ```
  Exit codes: 10 mobile disabled, 11 identity unavailable, 12 lock held, 13 bind refused.
- **Minimal child set** is the four children above. Nothing under `Aiur.PubSub`, no Phoenix endpoint
  (the gateway serves JSON only, so a `Plug.Router` suffices), no `Aiur.Exchange`, no orchestrator.
- **Bind guard:** while this ticket is alone, the gateway refuses any non-loopback `gateway.host`
  (exit 13); MP-N2-C10-T02 relaxes it for TLS or the overlay flag.
- **Logging:** to `<state>/machine/gateway.log` via the Logger file backend already used by
  `Aiur.LogFile` (verify that module can be configured without `Aiur.Application`; if not, log to stderr,
  which the launcher redirects in T02).

## Implementation steps

1. `src/lib/aiur/cli.ex`: parse and dispatch `__machine-gateway` (≈15 lines).
2. `src/lib/aiur/machine/gateway/{boot,supervisor,router,pid_file,store_lock_holder}.ex` (PROPOSED, ≈180 lines).
3. Tests.

## Non-happy paths

| Case | Result |
|---|---|
| Mobile disabled | exit 10 with "run `aiur mobile enable`". |
| Second gateway | `StoreLockHolder` sees a live holder → exit 12 "gateway already running (pid N)" (contract §9). |
| Port 4710 in use by something else | Bandit start fails → exit 13 naming the port and the `gateway.port` key. |
| Store corrupt | The router answers `503 {"error":"store_corrupt"}` on every `/v1` route; `/healthz` reports it. Fail closed, contract §9. |
| Crash of a child | `:one_for_one` restarts it; the lock holder crashing releases and re-acquires (its `terminate/2` releases). |

## Compatibility and rollout

New internal verb; no change to instance boot. The double-underscore name marks it internal; it is not
documented as a user command (the user command is `aiur mobile gateway start`, T02).

## Verification

`src/test/aiur/machine/gateway_boot_test.exs` (temp HOME; `async: false`):

1. `"gateway supervisor starts with zero instances and serves /healthz"` (start the supervisor on port 0 in-test).
2. `"gateway boot never starts the :aiur application"` — `Boot.run/1` takes an injectable
   `ensure_started` function; the test records every application it is asked to start and refutes
   `:aiur`. *Fails without:* the separate entry (mutation: add `:aiur` to the started list → fails).
   The real-process check (no orchestrator, no tmux, no workflow read when started from `/tmp`) is the
   launcher test in MP-N2-C4-T02.
3. `"second gateway exits with lock held"`. *Fails without:* the lock-holder child.
4. `"corrupt store makes /v1 routes 503 store_corrupt"`.
5. `"non-loopback gateway.host is refused"` (future relaxation in C10-T02 updates this test).
6. `"cli parses __machine-gateway"` in `src/test/aiur/cli_test.exs`.

`mix test` boots the `:aiur` application in the test VM, which can overwrite
`~/.aiur/github-budget/agent-token`; the command below sets a temporary HOME for that reason.

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/gateway_boot_test.exs test/aiur/cli_test.exs
```

Manual: `scripts/aiurdev build`; `aiur mobile enable`; run the T02 start command from `/tmp`
(no `.aiur/config` there) and confirm `epmd -names` lists `aiur-$USER-machine` and `curl
http://127.0.0.1:4710/healthz` answers, while no tmux session or orchestrator log appears.

## Completion and handoff

- [ ] Tests pass; mutation for 2 and 3 recorded.
- [ ] Docs: none (internal entry); T02 documents the user command.
- [ ] Dependents: T02, T03, T04, MP-N2-C10-T02.
