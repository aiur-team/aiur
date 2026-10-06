---
ticket_id: MP-N2-C7-T01
feature_id: MP-N2
chunk_id: MP-N2-C7
bucket: 3-mobile-watch
title: "Device management: list, rename and revoke (gateway endpoints and `aiur mobile devices|revoke`), children cascade"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C5-T03, MP-N2-C6-T01, MP-N2-C1-T02, MP-N2-C1-T04, MP-N2-C3-T02]
prior_units: [U1, U9]
prior_boundaries: [CLI, K]
prior_features: [MP-N7]
prior_findings: [security M1 (no cross-BEAM broadcast; watcher publishes)]
size_owner: "n/a (new modules); engine dispatch lines shared with U1/U9"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C7-T01 — List, rename, revoke

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C7 "Revocation, unpair-all and device management".
- **User value:** the operator sees every paired phone and watch, and removes one from the
  terminal or from another paired phone; the removed device loses access on its next request.
- **Deliverable:** gateway `GET /v1/devices`, `POST /v1/devices/<id>/rename`, `DELETE /v1/devices/<id>`
  (contract §4.5) and CLI `aiur mobile revoke <device_id>`, `aiur mobile rename <device_id> <label>`
  (`aiur mobile devices [--json]` is MP-N2-C3-T02; this ticket only adds `push_state` to its rows). Revoke deletes the row, its token hashes and every child
  (`parent_device_id`, contract RC-4 / MP-N7), appends `revoked` to the journal, and enqueues push
  deregistration (C7-T03).
- **Non-goals:** unpair-all (C7-T02), app screens (C7-T04).

## Dependencies and blockers

DESIGN-N2 (CLI output copy); MP-N2-C1-T02 (rows, lock, CLI-writes-when-gateway-down rule),
MP-N2-C1-T04 (journal), MP-N2-C3-T02 (dispatch), MP-N2-C5-T03 (token auth on the gateway),
MP-N2-C6-T01 (instances must reject the revoked token: verified by an integration test here).
Concurrent with C7-T02. Dependents: C7-T03, C7-T04, MP-N2-C9-T02 row R1.

## Verified starting point (base `45a290e3`)

Nothing exists. Contract §4.5, §5 (single writer + CLI fallback under the launcher lock pattern
`acquire_aiur_launch_lock`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh:1522-1567`), §2 rule 3
(revocation cannot recall plaintext already received).

## Chosen design

- `Machine.Devices.revoke(store, device_id, actor)` (PROPOSED): under the lock, collect the device
  and its descendants, delete them, write `devices.json` atomically, append one `revoked` journal
  entry per device with `actor ∈ {cli, device:<id>}`. Returns `{:ok, %{revoked: [ids],
  push: :pending}}`. Unknown id → `{:error, :device_unknown}`; the HTTP layer returns `404
  device_unknown`, which clients treat as success (contract §4.5).
- A device may revoke itself (app "Remove this phone").
- CLI path: the write routing of MP-N2-C3-T02 (gateway up → RPC to the gateway node named by
  MP-N2-C4-T01; gateway down → locked direct store write). Both paths call the same function.
- `GET /v1/devices` fields: `device_id, label, platform, paired_at, last_seen_at, parent_device_id,
  push_state` (from MP-N4-C3-T03 when present, else `unknown`); ages rendered by the CLI (AGENTS.md).
- Rename: label 1–64 printable chars; no effect on identity.

## Implementation steps

1. `src/lib/aiur/machine/devices.ex`. 2. Gateway routes. 3. CLI verbs in `src/lib/aiur/machine/cli.ex` (MP-N2-C3-T02) and
   engine dispatch. About 200 production lines.

## Non-happy paths

| Case | Behaviour |
|---|---|
| Revoke while that device refreshes its token | Lock serialises; the refresh after the revoke gets `device_revoked`. |
| Revoke the only device from the CLI | Allowed; the phone shows "removed" on next use. |
| Offline device | Learns on the next request (`401 device_revoked`) and wipes local state (MP-N2-C7-T04 / MP-N1-C3-T02). |
| Gateway down, CLI revoke | Direct store write; instances see it via mtime (C6-T01). |

## Compatibility and rollout

New verbs only.

## Verification

`src/test/aiur/machine/devices_test.exs`:

1. `"revoke deletes the device, its tokens and its children"`. *Fails without:* the cascade
   (mutation: delete only the row → child token still verifies, test fails).
2. `"revoked token is rejected by an instance on the next request"` (integration with
   `AiurWeb.DeviceAuth`, no restart).
3. `"revoking an unknown device returns device_unknown"`.
4. `"cli revoke writes the store directly when the gateway is down, under the lock"`.
5. `"journal records actor and never tokens"`.
6. `"devices --json rows carry push_state"` (extends the MP-N2-C3-T02 golden output).

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/devices_test.exs
```

## Completion and handoff

- [ ] Tests pass with mutation checks.
- [ ] Docs: `website/docs-app/reference/cli.md` (`aiur mobile revoke|rename`; `devices` gains `push_state`).
- [ ] Dependents: MP-N2-C7-T03 (deregistration), MP-N2-C7-T04 (app).

## Phase D additions (contract requests)

- **CR-R2-5, corrected in Phase D (security M1):** the revoke writer (gateway or CLI) does
  **not** broadcast to instances: they are other BEAMs, and a writer-side PubSub message never
  reaches them. Each instance's `Aiur.Machine.Store.Watcher` (MP-N2-C1-T03) sees the
  `devices.json` change and publishes `{:devices_revoked, ids}` (children included, because
  the cascade removes their rows in the same write) on its **local** `devices:revoked` topic.
  MP-R2-C7-T05 closes `events:feed` channels, MP-E5-C8-T02 ends `/voice/device` sessions and
  MP-N2-C6-T02 disconnects device LiveViews on it. This ticket's obligation is only that the
  revoke is **one atomic `devices.json` rename** that removes the row and its children.
  Test: `"revoke of a phone removes the phone and its watch in one rename"` — a stat-polling
  probe in the test sees exactly one inode change and both ids gone. *Fails without:* the
  single-write cascade (two writes → the probe sees an intermediate file). The end-to-end
  latency test is MP-N2-C1-T03 test 9 and the per-surface rows of the pairing security
  sibling §S2.
- **CR-N4-3:** `PUT /v1/devices/self/push` (own row only) replaces the caller's opaque
  `push_registration` (token refresh, key rotation, `capabilities.notifications_permitted`);
  the gateway stays the single writer. Consumers: MP-N4-C4-T05, MP-N4-C5-T05.
- **CR-N5-2 b:** the same atomic write deletes the device's section of
  `notification-preferences.json` (pairing §5).
