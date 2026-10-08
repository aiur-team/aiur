---
ticket_id: MP-N2-C2-T02
feature_id: MP-N2
chunk_id: MP-N2-C2
bucket: 3-mobile-watch
title: Remove the advert on clean shutdown and define the stale-advert rule
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C2-T01]
prior_units: []
prior_boundaries: [CLI]
prior_features: []
prior_findings: []
size_owner: "shutdown.ex (U8 ledger owner; look up at the implementation SHA)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C2-T02 — Advert removal and staleness

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C2.
- **User value:** a phone shows a cleanly stopped instance as stopped, not as stale or live.
- **Deliverable:** a new `Aiur.Shutdown.cleanup/1` phase `remove_advert` and the launcher
  `session_cleanup`/`stop` paths removing `<slug>.advert.json` next to the `.instance` record;
  `Aiur.Machine.Advert.stale?/2` (age > 90 s) used by T04.
- **Non-goals:** deleting `.instance` records (launcher-owned) or any other instance's advert.

## Dependencies and blockers

DESIGN-N2 gate; MP-N2-C2-T01. Dependents: MP-N2-C2-T04.

## Verified starting point (base `45a290e3`)

- `Aiur.Shutdown.cleanup/1` runs best-effort phases through `safely/2` (`src/lib/aiur/shutdown.ex:42-63`),
  called from `Aiur.Application.stop/1` (`src/lib/aiur.ex:520-526`).
- The launcher deletes the record on clean session exit (`aiur-engine.sh:2104`) and in `aiur stop`
  (`:3619`). A crash leaves both record and advert behind; T04 classifies that as `crashed` (record
  + node down) regardless of advert age.

## Chosen design

- BEAM side: phase `safely(fn -> Aiur.Machine.AdvertWriter.remove_own() end, "remove_advert")`
  appended to `cleanup/1`. `remove_own/0` deletes only the path computed from this node's slug.
- Launcher side (belt and braces when the BEAM was killed): add
  `rm -f "${record%.instance}.advert.json"` beside the two existing `rm -f "$(aiur_instance_record_path)"`
  lines. The launcher computes the same slug, so no new identity logic.
- Stale rule: `stale?(advert, now)` is true when `now - heartbeat_at > 90 s` or `heartbeat_at`
  is unparsable (unparsable is reported as `unknown` by T04, not as live).

## Implementation steps

1. `shutdown.ex`: one phase line. 2. `aiur-engine.sh`: two `rm -f` lines (shared with U1/U9;
recheck line numbers). 3. `advert.ex` (PROPOSED) `stale?/2`. About 30 production lines.

## Non-happy paths

SIGKILL → advert stays; T04 shows `crashed` (record present + node down) or `stopped` (no record).
Shutdown phase failure → logged by `safely/2`, no crash.

## Compatibility and rollout

Only affects files created by T01.

## Verification

1. `src/test/aiur/shutdown_test.exs` (existing): `"cleanup removes only this node's advert"` — two advert files in a temp instances dir, one removed. *Fails without:* the new phase.
2. `src/test/aiur/machine/advert_test.exs`: `"91 s old heartbeat is stale; 89 s is not; garbage is stale"`.
3. Engine: `src/test/aiur_engine_stop_pidfile_test.exs` pattern — add `"aiur stop removes the advert next to the record"`. *Fails without:* the `rm -f` line.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/advert_test.exs test/aiur/shutdown_test.exs test/aiur_engine_stop_pidfile_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation for 1 and 3 recorded. - [ ] Dependent: MP-N2-C2-T04.
- Docs: none in this ticket. It adds an internal shutdown phase and a staleness predicate, with no
  config key, CLI verb or user-facing surface (AGENTS.md "Docs ship with the change"). The
  `stopped` and `stale` states a user sees are documented with `aiur mobile status`
  (MP-N2-C3-T03, `reference/cli.md`) and in the pairing guide (MP-N2-C9-T01).
