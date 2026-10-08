---
ticket_id: MP-N2-C2-T04
feature_id: MP-N2
chunk_id: MP-N2-C2
bucket: 3-mobile-watch
title: Registry state machine (live/starting/stale/crashed/stopped/unknown) as a pure function, plus known_instances
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C2-T02, MP-N2-C2-T03, MP-N2-C1-T02]
prior_units: []
prior_boundaries: [CLI, PRJ]
prior_features: [MP-N3]
prior_findings: [MP-N2 F4]
size_owner: n/a (new file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C2-T04 — Registry state machine

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C2.
- **User value:** the phone never shows a dead instance as live, and never shows "unknown" as idle.
  The same function feeds `aiur mobile status` and the gateway API, so both agree.
- **Deliverable:** `Aiur.Machine.Registry.classify(records, adverts, liveness, known, now) :: [InstanceEntry]`
  (PROPOSED, pure) implementing contract §6.3, and `Registry.snapshot/1` that gathers the inputs
  (records via T03, adverts, epmd liveness, `known_instances.json` via C1-T02) and updates
  `known_instances` (7-day retention, OQ-N2-6 default).
- **Non-goals:** the per-instance summary (MP-N3-C2), HTTP (MP-N2-C4-T04).

## Dependencies and blockers

DESIGN-N2 gate (OQ-N2-6 retention is an owner value; 7 days is the default until answered);
MP-N2-C2-T02 (`stale?/2`), MP-N2-C2-T03 (parser), MP-N2-C1-T02 (`known_instances` storage).
Dependents: MP-N2-C3-T03, MP-N2-C4-T04, MP-N3-C2.

## Verified starting point (base `45a290e3`)

- epmd liveness probe in the launcher: `probe_node_liveness` runs `epmd -names` and matches
  `name <short> at port` (`aiur-engine.sh:2136-2149`), returning `up|down|unknown`. In the gateway
  BEAM the equivalent is `:erl_epmd.names/1` (`{:ok, [{name, port}]}`; Erlang `erl_epmd` module,
  <https://www.erlang.org/doc/apps/kernel/erl_epmd.html>, OTP 29 docs, accessed 2026-10-06; same API in OTP 28).
- Records deleted on clean stop (`aiur-engine.sh:2104`, `:3619`) — so record + node down = crashed (plan F4).
- Contract §6.3 table and the 90 s / 5 min thresholds.

## Chosen design

Evaluation order per instance key (union of records, adverts, known list), first match wins:

| # | Condition | State | `state_reason` |
|---|---|---|---|
| 1 | liveness `unknown` (epmd unreachable) | `unknown` | `liveness_unknown` |
| 2 | record present, node `down` | `crashed` | `node_down_record_left` |
| 3 | node `up`, advert present and not stale | `live` | — |
| 4 | node `up`, no advert, record younger than 5 min | `starting` | `no_advert_yet` |
| 5 | node `up`, advert stale or absent beyond 5 min | `stale` | `advert_stale` / `no_advert` |
| 6 | no record, node `down`, key in `known_instances` within 7 days | `stopped` | `clean_stop` |
| 7 | anything else (e.g. advert present, no record, node down) | `unknown` | `evidence_conflict` |

- `unknown` is never upgraded to `live` (contract). A collapsed cause is `unknown`, never a specific
  one (AGENTS.md).
- `last_seen_at` = advert `heartbeat_at`, else record `WRITTEN_AT`, else the known-list timestamp.
- `dashboard.reachable_for_devices`/`reason` from the advert: `bound: false` → `not_bound`;
  `transport: "none"` → `tls_unavailable` (or `cleartext_not_allowed` when an HTTP non-loopback URL
  exists but overlay is off); `loopback_only` with no device URL → `loopback_only`;
  `mobile_device_auth: false` → `device_auth_off`; else true. Unclassified → `unknown`.
- `known_instances` entry: `{instance_id, repository, project_root_basename, last_seen_at}`; entries
  older than 7 days are dropped on each snapshot. Written under the store lock only when changed.

## Implementation steps

1. `src/lib/aiur/machine/registry.ex` (PROPOSED): `classify/5` (pure), `snapshot/1` (I/O, injectable).
2. Tests. About 200 production lines.

## Non-happy paths

Covered by the table. Two adverts for one instance key (should not happen; slug is unique) → newest
heartbeat wins, `state_reason` gains `duplicate_advert`.

## Compatibility and rollout

Pure library; no behaviour change until C3-T03/C4-T04 call it.

## Verification

`src/test/aiur/machine/registry_test.exs` — table-driven, one case per row plus:

1. `"advert fresh but node down is crashed, not live"` (chunks.md). *Fails without:* row 2 ordering
   before row 3 (mutation: swap → fails).
2. `"evidence missing is unknown"`; mutation: default `_ -> :live` → fails (chunks.md).
3. `"epmd unreachable makes every instance unknown"`.
4. `"no-dashboard advert reports reachable_for_devices false with reason not_bound"`.
5. `"transport none reports tls_unavailable"`.
6. `"stopped instance disappears after 7 days"` (injected `now`).
7. `"unclassified dashboard reason is unknown"` — mutation: map fallback to `:loopback_only` → fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/registry_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation for 1, 2, 7 recorded.
- [ ] Dependents: MP-N2-C3-T03, MP-N2-C4-T04, MP-N3-C2-T01.
