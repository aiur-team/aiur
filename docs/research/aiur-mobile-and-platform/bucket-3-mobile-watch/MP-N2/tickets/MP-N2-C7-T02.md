---
ticket_id: MP-N2-C7-T02
feature_id: MP-N2
chunk_id: MP-N2-C7
bucket: 3-mobile-watch
title: "Unpair-all: one atomic store write from any paired device or `aiur mobile unpair-all`, with a split control/push result"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C7-T01]
prior_units: [U1, U9]
prior_boundaries: [CLI, K]
prior_features: [MP-N4]
prior_findings: [security M1]
size_owner: n/a (new modules)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C7-T02 — Unpair-all

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C7.
- **User value (D19):** after losing a phone, the operator cuts off every device of the machine
  from any other paired device, or from the terminal, in one action, and is told honestly that
  push deregistration may still be pending.
- **Deliverable:** `POST /v1/devices/unpair-all {"confirm": machine_label}` (token) and
  `aiur mobile unpair-all [--yes]`. One atomic write empties `devices.json` and `pairing.json`
  (all tokens and outstanding secrets die), appends one `unpair_all` journal entry, enqueues push
  deregistration for every removed device, and returns
  `{control: "revoked", devices: N, push: {pending: [ids], done: [ids]}}`.
- **Non-goals:** machine identity reset (`aiur mobile reset` → MP-R1 identity reset path, RC-01);
  this keeps `machine_id` and `machine_key`, so a re-pair needs no new QR trust.

## Dependencies and blockers

DESIGN-N2 (confirmation and result copy); MP-N2-C7-T01 (`Devices` module). Dependents: C7-T03,
C7-T04, MP-N2-C9-T02 row R2.

## Verified starting point (base `45a290e3`)

Nothing exists. Contract §4.5 (calling device included; result split per Khala KHA-128 rule),
§2 rule 3.

## Chosen design

- `confirm` must equal the current `machine_label` exactly (case-sensitive); mismatch → `400
  confirm_mismatch`. The CLI prompts for the label unless `--yes`.
- The calling device's own token is deleted in the same write; the HTTP response is still sent
  (computed before the write is visible to verification).
- Push results come from C7-T03's outbox: immediately after the write all are `pending`; the CLI
  waits up to 5 s for the outbox and prints the final split; the HTTP endpoint returns at once with
  `pending`.

## Implementation steps

`Devices.unpair_all/2`, route, CLI verb. About 90 production lines.

## Non-happy paths

Store write failure → nothing changed, `503 store_unavailable`; concurrent claim during unpair-all →
lock order makes the claim either fully before (then deleted) or after (then valid, the operator
sees it in `devices`); push relay unreachable → `pending` with retry (C7-T03).

## Compatibility and rollout

New verb and route.

## Verification

`src/test/aiur/machine/unpair_all_test.exs`:

1. `"unpair-all from device B removes A and B and every secret in one write"`. *Fails without:*
   including the caller (mutation: skip the caller → B's token still verifies).
2. `"wrong confirm label changes nothing"`. 3. `"outstanding QR secrets stop working"`.
4. `"response reports control and push separately"`. 5. `"one unpair_all journal entry"`.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/unpair_all_test.exs
```

## Completion and handoff

- [ ] Tests pass with mutation checks (MP-N2 plan acceptance 6).
- [ ] Docs: CLI reference `aiur mobile unpair-all`; pairing guide "Lost phone".
- [ ] Dependents: MP-N2-C7-T04.
- **Phase D:** the unpair-all write also deletes every device section of
  `notification-preferences.json` (CR-N5-2 b). The revocation reaches live sockets through each
  instance's store watcher, not through a broadcast from the writer (security M1; same as
  MP-N2-C7-T01). Test: `"unpair-all empties devices.json in one rename"` (stat probe sees one
  inode change). *Fails without:* the single atomic write.
