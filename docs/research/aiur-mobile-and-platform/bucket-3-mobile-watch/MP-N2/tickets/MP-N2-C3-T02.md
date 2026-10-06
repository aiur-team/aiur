---
ticket_id: MP-N2-C3-T02
feature_id: MP-N2
chunk_id: MP-N2-C3
bucket: 3-mobile-watch
title: "`aiur mobile` launcher dispatch, enable/disable/devices, and CLI write routing (gateway up → RPC, gateway down → locked direct write)"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C3-T01, MP-N2-C1-T01, MP-N2-C1-T02, MP-N2-C1-T04]
prior_units: [U1, U9]
prior_boundaries: [CLI]
prior_features: []
prior_findings: [RQ-N2-6]
size_owner: "aiur-engine.sh and cli.ex (U1/U9 share the engine; look up owners at the implementation SHA)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C3-T02 — `aiur mobile` dispatch and the write path

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C3.
- **User value:** an operator who skipped mobile setup can enable it later with one command, from any
  directory, through both `aiur` and `aiurdev` (one engine, AGENTS.md), and see paired devices.
- **Deliverable:**
  - Engine dispatch `mobile)` in `aiur-engine.sh` main `case` routing to `cmd_mobile` with subcommands.
    This ticket implements `enable`, `disable`, `devices [--json]`. It reserves (prints "not available
    yet" until their tickets land) `status` (C3-T03), `qr` (C5-T01), `revoke`, `unpair-all`,
    `rename` (C7), `gateway start|stop|status` (C4-T02), `tls …` (C10-T03/T04), `reset` (C7).
  - `Aiur.Machine.CLI` (PROPOSED) with one function per verb, callable two ways (below).
  - `enable`: `Store.identity/0` (fail closed with the RC-01 message), `Store.init_machine_key/0`,
    `Settings.write(mobile.enabled: true)`, journal `mobile_enabled`, then prints next steps
    (DESIGN-N2 copy). `disable`: `mobile.enabled: false`, journal entry; keeps devices (re-enable
    restores them) and says so.
- **Non-goals:** the copy itself (DESIGN-N2), `aiur init` step (T04).

## Dependencies and blockers

DESIGN-N2 (CLI copy for every state in its table: success, disabled, error). MP-N2-C3-T01,
C1-T01, C1-T02, C1-T04. Dependents: T03, T04, MP-N2-C4-T02, MP-N2-C5-T01, MP-N2-C7-*, MP-N2-C10-T03/T04.

## Verified starting point (base `45a290e3`)

- Engine main dispatch: `case` arms such as `status)`, `agents)`, `commands)` (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:4109-4130`).
- Two existing BEAM entry modes: `build_release_cmd` (named node, `--eval "Aiur.CLI.main(Aiur.CLI.argv_from_file())"`,
  `:420-431`) and `build_init_cmd` (distribution-free `start_clean` boot for the init wizard,
  `:436-446`). `--todo` likewise "runs under the distribution-free start_clean boot and never starts
  Aiur's supervision tree" (`src/lib/aiur/cli.ex:100-103`).
- Control RPC with a watchdog timeout: `run_release_rpc_with_timeout` (`aiur-engine.sh:2333-2387`),
  default 10 s (`control_rpc_timeout_seconds`, `:2273-2279`), target chosen by `RELEASE_NODE`.
- Node liveness for a named node: `probe_named_node_liveness` (`:2166-2172`).
- `Aiur.CLI.main/1` dispatches tagged tuples (`src/lib/aiur/cli.ex:63-72`).

## Chosen design

**Write routing (completes RQ-N2-6 on the CLI side).**

```text
cmd_mobile <verb> …
  if verb is read-only (devices, status): distribution-free eval; reads the store directly (no lock)
  else (enable, disable, later revoke/unpair-all/rename/qr):
    state=$(probe_named_node_liveness "aiur-${USER}-machine@127.0.0.1")
    up      → RELEASE_NODE=<gateway node> run_release_rpc_with_timeout "Aiur.Machine.CLI.<verb>(<args>)"
              (the gateway holds the store lock for its lifetime, MP-N2-C1-T02, so it performs the write)
    down    → distribution-free eval `Aiur.CLI.main(["mobile", verb, …])`, which takes the store lock
    unknown → refuse with exit 3 "cannot tell whether the gateway is running (epmd unreachable)";
              never write while the holder is unknown.
```

- `Aiur.CLI` gains `{:mobile, verb, args}` in `evaluate/1` and `dispatch/1`; it calls
  `Aiur.Machine.CLI.<verb>/1` and `System.halt(code)` like `run_todo_command/2` (`cli.ex:94-105`).
- Exit codes: 0 ok; 2 usage; 3 gateway state unknown; 4 identity unavailable (RC-01); 5 store error
  (corrupt, locked timeout); 6 settings invalid (prints every dotted key).
- `devices --json`: `{machine_id, observed_at, devices: [{device_id, label, platform, paired_at,
  last_seen_at, parent_device_id, last_seen_age_s}]}` — ages rendered (AGENTS.md); no token hashes.
- Both `scripts/aiurdev` and the npm `aiur` reach this through the shared engine (AGENTS.md "Layout").

## Implementation steps

1. Engine: `mobile)` arm + `cmd_mobile` (≈70 lines) using existing helpers.
2. `src/lib/aiur/cli.ex`: parse `mobile` and dispatch (≈30 lines).
3. `src/lib/aiur/machine/cli.ex` (PROPOSED): `enable/1`, `disable/1`, `devices/1` (≈120 lines).
4. Tests and docs.

## Non-happy paths

| Case | Result |
|---|---|
| `identity.json` missing | exit 4 "start any aiur instance once to create this machine's identity" (copy per DESIGN-N2). |
| Gateway up but RPC times out | exit 5 naming the gateway node; nothing written locally. |
| Store locked by a crashed CLI | the lock reclaim of C1-T02 applies. |
| `enable` twice | idempotent; prints the current state. |
| Run from inside an agent workspace | allowed (pure local files); no `--test` guard involvement. |

## Compatibility and rollout

New verb; no existing command changes. `aiur` in an unconfigured directory behaves as before (T01 test 7).

## Verification

- `src/test/aiur/machine/cli_test.exs` (temp HOME; no gateway):
  1. `"enable creates the machine key and sets mobile.enabled, without ~/.aiur/config"` (acceptance 2).
  2. `"enable without identity exits 4 and creates nothing"`. *Fails without:* the RC-01 guard.
  3. `"disable keeps device rows"`.
  4. `"devices --json renders last_seen_age_s and contains no token hash"` (grep for `hash`).
     *Fails without:* the projection that drops `token_hashes` (mutation: dump the row → fails).
- Engine routing, `src/test/aiur_engine_mobile_dispatch_test.exs` (new; shell-level, fake
  `release_bin` script and fake epmd output as `src/test/aiur_engine_stop_pidfile_test.exs` does):
  5. `"enable routes to rpc when the gateway node is up"`; 6. `"… to direct eval when down"`;
  7. `"refuses with exit 3 when liveness is unknown"`. *Fails without:* the unknown branch
  (mutation: treat unknown as down → fails).
  8. `"aiurdev and aiur share the dispatch"` — invoke via `scripts/aiurdev mobile devices --json` and
     the engine directly with the same fake release; outputs equal.

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/cli_test.exs test/aiur_engine_mobile_dispatch_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation for 2, 4, 7 recorded.
- [ ] Docs: `website/docs-app/reference/cli.md` gains `aiur mobile enable|disable|devices` (and lists
      the reserved verbs as "added by" later releases only when they ship — do not document unshipped verbs).
- [ ] Dependents: T03, T04, MP-N2-C4-T02, MP-N2-C5-T01, MP-N2-C7-*.
