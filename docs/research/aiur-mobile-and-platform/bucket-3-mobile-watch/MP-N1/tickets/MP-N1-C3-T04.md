---
ticket_id: MP-N1-C3-T04
feature_id: MP-N1
chunk_id: MP-N1-C3
bucket: 3-mobile-watch
title: Native watch snapshot builder — compact per-instance Facts plus pre-resolved affordances, under a size budget
status: blocked
blocked_by: [DESIGN-N1, DESIGN-N7, MP-N1-C3-T03, MP-N1-C2-T03, MP-N3-C2-T01, MP-N3-C3-T01, MP-N3-C3-T02]
prior_units: []
prior_boundaries: []
prior_features: [MP-N3, MP-N7]
prior_findings: []
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C3-T04 — Watch snapshot projection (native)

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C3.
- **User value:** the watch's compact instance list (brief N7) shows executor state, active
  agents, awaiting Commands and build progress with their age, and marks absent data as
  unavailable rather than zero, without the watch ever talking to a daemon.
- **Deliverable:** `WatchSnapshotBuilder` in both native cores: input = the signed
  `GET /v1/instances?include=summary` responses per machine (contract §6.3/§7) + phone
  reachability per machine + native resolver; output = the `snapshot` message body of the
  MP-N7 watch-link protocol (MP-N7 plan §4/§6), extending `client-capability-model.md` §7:

```json
{ "v": 1, "as_of": "…", "machines": [ { "machine_id": "…", "label": "…",
    "reachability": "reachable|unreachable|revoked", "observed_at": "…" } ],
  "instances": [ { "instance_id": "<machine_id>/<instance_key>", "label": "owner/name",
      "disambiguator": "root-basename|null", "state": "live|starting|stale|stopped|crashed|unknown",
      "facts": { "agents_active": Fact, "fleet_paused": Fact, "commands_awaiting": Fact,
                 "commands_awaiting_blocking": Fact, "executor": Fact, "build_progress": Fact },
      "affordances": { "answer_command": {…}, "mic_dictate_server": {…},
                       "mic_dictate_system": {…}, "mic_converse": {…}, "build_progress": {…} } } ] }
```

  `Fact` is the contract §7 envelope unchanged (`status`, `value?`, `observed_at`, `age_ms`,
  `reason?`, `lower_bound?`). The watch applies MP-N3's `MetaRow` display rules to Facts.
- **Non-goals:** sending the snapshot (MP-N7-C1-T02/T03 + T05 triggers); watch rendering.

## Dependencies and blockers

- DESIGN-N1, DESIGN-N7 (D-N7-7 short labels do not change the payload, but D-N7-8 context
  depth may add fields; the gate applies).
- MP-N1-C3-T03 (native resolver), MP-N1-C2-T03 (signed registry fetch).
- **MP-N3-C2-T01** (gateway fan-out serving `?include=summary`), **MP-N3-C3-T01** (MetaRow model) and **MP-N3-C3-T02** (MetaRow JSON
  fixtures, reused here as inputs and by the watch as expected renders).

## Verified starting point (base 45a290e3)

- Contract §7 field list and sources (`Orchestrator.dashboard_snapshot/2` at
  `src/lib/aiur/orchestrator.ex:684`; `Aiur.DecisionQuery.counts/1` at
  `src/lib/aiur/decision_query.ex:76-96`; `Aiur.Executor.Roster.build/1` at
  `src/lib/aiur/executor/roster.ex:50-67`; `RootSummary.progress` at
  `src/lib/aiur/build_order/root_summary.ex:21-22`). The summary budget is < 4 KiB per instance
  and carries no Command text (contract §7).
- WatchConnectivity application context is a property-list dictionary; Apple documents no fixed
  size but recommends small payloads (S6, <https://developer.apple.com/documentation/watchconnectivity>);
  Data Layer `DataItem` payload limit is 100 KB
  (<https://developer.android.com/training/wearables/data/data-items>, accessed 2026-10-06 —
  **UNVERIFIED** exact figure; the implementer confirms on the page and records it).

## Chosen design

- **Budget:** serialized snapshot ≤ 16 KiB; when larger, drop instances in this order:
  `stopped`, then `crashed`, then oldest `stale`, and set `"truncated": N`. Live instances are
  never dropped silently (truncation count is shown by the watch).
- **Build progress:** copies MP-N3's chosen rule (DESIGN-N3 Q3) through a single
  `build_progress` Fact; until DESIGN-N3 decides, the builder emits the Fact for the most
  recently active root, as MP-N3 plan §3 recommends, and the field is behind the DESIGN-N3 gate.
- **Unreachable machine:** its instances keep last-known Facts from the builder's in-memory
  previous snapshot with their original `observed_at` and the machine `reachability:
  unreachable`; affordances resolve to `unreachable`. No zeros are synthesised.
- **Revoked:** the machine and its instances are removed; `machines[]` keeps one entry with
  `reachability: revoked` for one snapshot so the watch can clear its cache.
- No secrets, no Command question text, no ticket titles.

## Implementation steps

1. `WatchSnapshot` models (generated where the schema exists; snapshot schema added to
   `fixtures/watch-link/` by MP-N7-C1-T01 — this ticket adds the `snapshot` schema first if
   MP-N7-C1-T01 has not).
2. `WatchSnapshotBuilder.swift` / `.kt`: pure function `(registryByMachine, reachability,
   previous, now) -> Snapshot`.
3. Budget/truncation and serialization helpers.
4. Fixture tests: inputs from MP-N3-C3-T02 fixtures + reachability cases.

## Non-happy paths

- Summary `unsupported` for an old instance → instance included with identity only, all Facts
  `{status: "unknown", reason: "summary_unsupported"}`.
- Gateway offline (`device_auth_disabled` / connection refused) → machine `unreachable`, cause
  kept in `machines[].cause`.
- Two clones of one repo → `disambiguator` = `project_root_basename`.
- Privacy: a lost watch shows repository names and counts only (same exposure as MP-N3 plan §5).

## Compatibility and rollout

- `v: 1`; the watch ignores unknown fields and rejects unknown major `v` with "Update the app".

## Verification

- Commands: the native test commands of MP-N1-C3-T03 with `-only-testing:…WatchSnapshotBuilderTests`
  / `--tests '*WatchSnapshotBuilderTest*'`.
- Cases:
  - `unavailable fact stays unavailable` (no `value` emitted). Mutation: default `value` to 0 →
    fails.
  - `unreachable machine keeps last facts with original observed_at`. Mutation: stamp `now` →
    fails.
  - `truncation drops stopped before live and reports count`. Mutation: drop from the end of
    the list → fails.
  - `snapshot contains no command text` (fixture registry with a `question` field injected →
    output scanned).
  - `snapshot under 16 KiB for 20 instances × 3 machines`.
- Device: exercised by DV-W3 (phone unreachable) and DV-W2 on Apple Watch A (watchOS 26.x) with
  iPhone A; Wear OS 5+ watch with Android phone A (MP-N7-C3).

## Completion and handoff

- [ ] Both ports pass the shared cases; mutations fail.
- **Docs:** none.
- **Dependents:** MP-N7-C1-T02, MP-N7-C1-T03, MP-N7-C1-T05.
