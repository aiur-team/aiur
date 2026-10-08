---
ticket_id: MP-N4-C3-T04
feature_id: MP-N4
chunk_id: MP-N4-C3
bucket: 3-mobile-watch
title: Push component supervision and the `push` capability (available / degraded / unavailable)
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C3-T03, MP-N4-C1-T01, MP-R1-C3-T01 (capability registry, RC-12)]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: [MP-R1]
prior_findings: [capability-matrix.md:65,87 (push row)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C3-T04 — Supervision and capability

## Identity and outcome

Bucket 3, MP-N4, chunk C3. Start the push component as an **optional** supervised child
of the daemon and report capability `push` through the MP-R1 registry, never silently
missing (AC-N4-8). States (identity-and-capabilities contract §2.2 enum only):

| Condition | State | Reason / extra |
| --- | --- | --- |
| `push.enabled: false` | `unavailable` | `disabled` |
| settings invalid | `unavailable` | `not_configured` |
| `Primitives.missing/0 != []` (C1-T01) | `unavailable` | `dependency_unavailable`, `depends_on: ["runtime.crypto"]` |
| machine store missing/corrupt, or mobile disabled | `unavailable` | `dependency_unavailable`, `depends_on: ["pairing"]` |
| enabled, no device has a valid `push_registration` | `available` | — (the device count is shown by `aiur push status`, C3-T07; `devices` is not a registered capability attribute, identity §2.2, X-34) |
| relay errors for ≥ 2 consecutive jobs across ≥ 60 s, or outbox unwritable, or invalid registration rows | `degraded` | `not_running` (relay/outbox) or `unknown` (mixed); the first-failure time is in `aiur push status` (C3-T07), not in the capability entry (no registered `since` attribute, X-34) |
| otherwise | `available` | — |

## Dependencies and blockers

- C3-T03, C1-T01, MP-R1 capability registry (`Aiur.Capabilities`, PROPOSED by MP-R1,
  each component registers `capabilities/0`; contract §2.4). DESIGN-N4: no UI here (the
  human-readable `aiur status` line is C3-T07).

## Verified starting point

- Capability contract §2.2: `state ∈ {available, degraded, unavailable, unknown}`; reasons
  `not_installed · not_configured · disabled · not_running · … · dependency_unavailable
  (with depends_on) · unknown`; "Collapsed or unclassified causes use `unknown`, never a
  specific cause" (AGENTS.md collapsed-cause rule).
- Capability matrix: `push` row (`bucket-1-refactor/MP-R1/capability-matrix.md:65,87`):
  needs pairing, commands, event-bus; without build-orders Commands still notify.
- Child placement: daemon children are built in `child_specs/1` from run-shape flags
  (`src/lib/aiur.ex:244-251`, cited by the capability contract §2.4).

## Chosen design

- `Aiur.Push.Supervisor` (PROPOSED, `:rest_for_one`): Settings watcher → Outbox → Sender
  scheduler. Started in every run shape that has the event bus (including `--bg` and
  `--no-dashboard`; push does not need the HTTP listener).
- `Aiur.Push.capabilities/0` computes the table above from cheap reads (settings,
  primitives cache, registry cache, sender health counters); never calls the relay.
- Health counters: consecutive relay failures and first-failure time kept in the Sender;
  reset on any `202`.
- State changes bump the registry `revision` (contract §2.2) so clients refetch.

## Implementation steps

1. `supervisor.ex`, `capability.ex` (PROPOSED); register with the MP-R1 registry.
2. Add the child to the composition root behind the component's presence (MP-R1 rule:
   an absent package has no callback).
3. Tests.

## Non-happy paths

- Registry not yet available (pre-R1): component still runs; `push` simply absent from
  the report until R1 lands — acceptable only because R1 is a hard predecessor in
  `blocked_by`.
- Sender crash → supervisor restarts; capability shows `degraded` until the
  next success; `aiur push status` shows since when.

## Compatibility and rollout

Default `disabled`. Run shapes unchanged otherwise.

## Verification

`src/test/aiur/push/capability_test.exs` (PROPOSED). Each `unavailable`/`degraded`
branch gets a test that fails if the branch is replaced with `available` (AGENTS.md
unknown-path rule):

| Test | Expected |
| --- | --- |
| `"disabled setting reports unavailable/disabled"` | exact map |
| `"missing crypto reports dependency_unavailable runtime.crypto"` | exact map (inject `missing/0`) |
| `"corrupt machine store reports dependency_unavailable pairing"` | exact map |
| `"two relay failures over 60 s report degraded"` | exact map `{state: degraded, reason: not_running}` with no unregistered keys (X-34) |
| `"mixed causes collapse to unknown, not to a specific reason"` | `reason: "unknown"` — must fail if replaced with `not_running` |
| `"success resets degraded"` | `available` |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/capability_test.exs`.

## Completion and handoff

- [ ] AC-N4-8 covered. Capability id `push` listed in the MP-R1 capability table (no new id).
- Docs: the capability reasons are documented with the capability report (MP-R1 docs);
  add `push` rows there if MP-R1's page lists per-id reasons.
- Dependents: C3-T07, MP-N5-C1-T03 (options availability), MP-N3 (instance view).
