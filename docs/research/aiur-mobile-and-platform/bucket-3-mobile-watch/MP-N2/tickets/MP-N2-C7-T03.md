---
ticket_id: MP-N2-C7-T03
feature_id: MP-N2
chunk_id: MP-N2-C7
bucket: 3-mobile-watch
title: "Push deregistration outbox: persisted intent, retries, `pending` reporting; calls MP-N4-C3-T05 when installed"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C7-T01, MP-N2-C4-T01]
prior_units: []
prior_boundaries: [K]
prior_features: [MP-N4]
prior_findings: []
size_owner: n/a (new modules)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C7-T03 — Deregistration outbox

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C7.
- **User value:** after a revoke, the removed phone stops getting notifications as soon as the
  relay can be reached, and the operator can see whether that has happened yet.
- **Deliverable:** `~/.config/aiur/machine/push_outbox.ndjson` with `{device_id, push_registration,
  enqueued_at, attempts, state: pending|done|failed_permanent}`, a gateway worker that calls the
  push component's `deregister/1`, exponential backoff (30 s → 1 h cap, 48 h give-up →
  `failed_permanent`), and `push_state` per revoked device in `aiur mobile status` and the C7-T01/T02
  responses.
- **Non-goals:** the relay protocol and `deregister/1` itself (MP-N4-C3-T05).

## Dependencies and blockers

DESIGN-N2; MP-N2-C7-T01; MP-N2-C4-T01 (worker lives in the gateway tree). **MP-N4 is optional**: if
the push component is not installed, the worker records `state: done, reason:
"push_not_installed"` (no registration can exist without it). It does not block on MP-N4; it calls
MP-N4-C3-T05's `deregister/1` through a behaviour once that ticket lands.

## Verified starting point (base `45a290e3`)

Nothing exists. MP-N4 chunks: `MP-N4-C3-T05 Deregistration function … that the MP-N2 gateway calls
on revoke and unpair-all … reported as "push deregistration pending"`
(`bucket-3-mobile-watch/MP-N4/chunks.md:92-95`). The push registration is stored opaquely in the
device row (contract §2, §4.1).

## Chosen design

- Behaviour `Aiur.Machine.PushDeregistrar` with `deregister(push_registration) :: :ok |
  {:retry, reason}` (Phase D: a relay `404`/unknown handle is `:ok`, so there is no separate
  `{:gone}`; MP-N4-C3-T05's `Aiur.Push.Deregister` implements it); implementation resolved at runtime via the MP-R1 capability registry
  (`push` capability present → MP-N4 module; absent → `Noop` returning `:ok` with the reason).
- The registration blob is copied into the outbox **before** the device row is deleted (same locked
  write), so revocation never loses what must be deregistered.
- Outbox rows never contain tokens. The blob is opaque but may identify the device to the relay, so
  the file is 0600 and pruned 7 days after `done`.

## Implementation steps

Behaviour, `Noop`, outbox writer (inside `Devices.revoke/unpair_all`), worker, status fields.
About 160 production lines.

## Non-happy paths

Relay down (retry, `pending` visible with age); gateway restart (worker resumes from the file);
push component removed after enqueue (rows resolved as `push_not_installed`); corrupt outbox line
(skipped and reported, never blocks other rows).

## Compatibility and rollout

Inert until a device has a push registration.

## Verification

`src/test/aiur/machine/push_outbox_test.exs` (fake deregistrar):

1. `"revoke enqueues the registration before deleting the row"` (kill between steps via injected
   failure; the outbox still has it). *Fails without:* write ordering.
2. `"retry with backoff then done"`. 3. `"48 h of failures becomes failed_permanent"`.
4. `"no push component: done with push_not_installed"`. 5. `"worker resumes after restart"`.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/push_outbox_test.exs
```

## Completion and handoff

- [ ] Tests pass with mutation checks.
- [ ] MP-N4-C3-T05 implements the behaviour (named in its ticket).
- [ ] Docs: CLI reference status field `push_state`.
