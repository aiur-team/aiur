---
ticket_id: MP-N2-C3-T03
feature_id: MP-N2
chunk_id: MP-N2-C3
bucket: 3-mobile-watch
title: "`aiur mobile status [--json]`: machine, gateway, devices, registry snapshot, with an age on every observed field"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C3-T02, MP-N2-C2-T04, MP-N2-C4-T02, MP-N2-C1-T03]
prior_units: [U9]
prior_boundaries: [CLI]
prior_features: []
prior_findings: [RC-42 integrity listing]
size_owner: n/a (new module; engine arm shared with U1/U9)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C3-T03 — `aiur mobile status`

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C3.
- **User value:** one command tells the operator whether a phone can pair and what it would see:
  mobile on/off, gateway running or not, how many devices, each instance's registry state with its
  age, crashed leftovers, and transport health (the transport block is added by MP-N2-C10-T02).
- **Deliverable:** `Aiur.Machine.CLI.status/1` and the engine's `mobile status` arm (read-only,
  distribution-free eval). Human output per DESIGN-N2; `--json` envelope:

```json
{ "contract": "aiur.mobile-status/v1", "observed_at": "…",
  "machine": {"machine_id": "…", "machine_label": "…", "identity": "ok|unavailable", "reason": null},
  "mobile": {"enabled": true, "settings_error": null},
  "gateway": {"state": "running|stopped|unknown", "node": "aiur-kevin-machine@127.0.0.1",
              "pid": 4242, "started_at": "…", "age_ms": 120000, "listen": "127.0.0.1:4710"},
  "devices": {"count": 2, "last_paired_at": "…"},
  "instances": [ { "instance_id": "…", "state": "crashed", "state_reason": "node_down_record_left",
                   "last_seen_at": "…", "age_ms": 3600000,
                   "dashboard": {"reachable_for_devices": false, "reason": "tls_unavailable"} } ],
  "journal_tail": [ {"at": "…", "event": "paired", "device_id": "…"} ] }
```

- **Non-goals:** the transport block (C10-T02), fixing anything (status never writes).

## Dependencies and blockers

DESIGN-N2 (status copy for: gateway off, no phone-reachable endpoint, crashed record present).
MP-N2-C3-T02 (dispatch), MP-N2-C2-T04 (registry), MP-N2-C4-T02 (gateway pid file and liveness).
Dependents: MP-N2-C9-T01 docs, MP-N2-C10-T02 (adds `transport`).

## Verified starting point (base `45a290e3`)

- Existing `aiur status` is an RPC to `Aiur.AgentControlCLI.status()` (`cmd_status`, `aiur-engine.sh:2611-2614`)
  and needs a running instance; `mobile status` must work with zero instances and no gateway.
- AGENTS.md "If a surface computes an age, it renders the age": CLI emits `observed_at`, `age_ms`, `freshness`.
- Crash leftovers are records whose node is down (plan F4); they are listed, never deleted (contract §6.3).

## Chosen design

- Gateway state from `<state>/machine/gateway.pid` (written by MP-N2-C4-T02) **and** epmd liveness of
  the gateway node: `running` only when both agree; `stopped` when neither; otherwise `unknown` with
  `reason` (`pid_alive_node_missing` / `node_up_pid_missing`).
- Instances: `Aiur.Machine.Registry.snapshot/1` (C2-T04) without summaries.
- Every observed timestamp is paired with `age_ms` computed at `observed_at`.
- Exit code 0 even when things are wrong (it is a report); `--check` flag returns 1 when mobile is
  enabled but the gateway is not running or no device endpoint exists (useful for scripts).
- No secret, token hash, key path or full project path in either output (test greps).
- **Needs attention (Phase D, RC-42):** `devices.integrity` = `Store.integrity/0` computed live
  (`{status: "ok"}` or a list of `{device_id, label, reason}`); the human output prints each under
  "Needs attention" with the fix `aiur mobile revoke <id>`, and `--check` returns 1 when the list
  is non-empty. An unreadable journal reports `integrity: {status: "unavailable"}`, never "ok".

## Implementation steps

1. `Aiur.Machine.CLI.status/1` + human renderer. 2. Engine arm. 3. Tests. About 180 production lines.

## Non-happy paths

Identity unavailable → `machine.identity: "unavailable"` with reason, rest still reported. Store
corrupt → `devices: {status: "unavailable", reason: "store_corrupt"}` — never `count: 0`.
Settings invalid → `mobile.settings_error` lists dotted keys; `enabled` reported as `null`, not false.

## Compatibility and rollout

Read-only new verb.

## Verification

`src/test/aiur/machine/status_test.exs`:

1. `"zero instances and no gateway report stopped and an empty list, not an error"`.
2. `"crashed record is listed with age_ms"`. *Fails without:* the age field (mutation: drop `age_ms` → golden fails).
3. `"corrupt store renders devices unavailable, never count 0"`. *Fails without:* the unavailable branch
   (mutation: default to `count: 0` → fails; AGENTS.md unknown-path rule).
4. `"pid alive but node missing is unknown, not running"`.
5. `"output contains no token, secret or full project path"` (fixture values grepped in both outputs).
6. `"--check exits 1 when enabled and gateway stopped"`.
7. `"a device row with no paired journal entry is listed under needs attention"` (RC-42). *Fails
   without:* the integrity field.
8. `"unreadable journal reports integrity unavailable, not ok"`. *Fails without:* the unavailable
   branch (mutation: default to ok → fails).
Golden files: `test/fixtures/machine/status_*.json`.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/status_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation for 2, 3 recorded.
- [ ] Docs: `website/docs-app/reference/cli.md` `aiur mobile status [--json] [--check]` with the JSON fields.
