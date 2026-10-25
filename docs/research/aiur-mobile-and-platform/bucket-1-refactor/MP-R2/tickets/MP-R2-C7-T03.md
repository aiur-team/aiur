---
ticket_id: MP-R2-C7-T03
feature_id: MP-R2
chunk_id: MP-R2-C7
bucket: 1 (Bucket-2-enabling, RC-09)
title: Advertise the events.export capability {v, retention} through the MP-R1 capability registry
status: blocked
blocked_by: [DESIGN-R2 §2, MP-R1-C3-T01 (Aiur.Capabilities registry + Provider behaviour), MP-R2-C6-T01, MP-R2-C7-T01]
prior_units: []
prior_boundaries: [BUS #10]
prior_features: [MP-R1 (capability registry, RC-12)]
prior_findings: [RC-ID-3]
size_owner: n/a (new provider < 80 lines; src/config/config.exs one list entry); re-checked against U8 assignments.csv at 761756f39 (no existing oversized edit)
base_sha: 761756f394e6783794c777668fc1a26a540e4059
researched: 2026-10-06
---

# MP-R2-C7-T03 — `events.export` capability

## Identity and outcome

- **Bucket 1, MP-R2, chunk C7. Bucket-2-enabling (RC-09).**
- **User value:** clients detect whether the event feed exists on an
  instance (and its retention) from `GET /api/v1/capabilities` /
  `aiur capabilities`, instead of probing `/api/v1/events` and guessing;
  MP-N3 shows "unavailable", never zeros (brief §7).
- **Deliverable:** `Aiur.Events.CapabilityProvider` implementing the
  PROPOSED `Aiur.Capabilities.Provider` behaviour, registered in
  `config :aiur, :capability_providers`; capability ID `events.export`.
- **Non-goals:** the registry, endpoint, CLI and `system.capabilities.changed`
  are MP-R1-C3; this ticket only contributes one provider.

## Dependencies and blockers

- **MP-R1-C3-T01** (registry + `Provider` behaviour) — external, not yet
  ticketed in files at research time; status `blocked` until it exists.
- C6-T01 (config keys to read), C7-T01 (route the capability describes).
- Identity contract RC-ID-3 adopts `events.export` with `{v, retention}`
  (`contracts/identity-and-capabilities.md` §5).

## Verified starting point (761756f394e6783794c777668fc1a26a540e4059)

Refreshed 2026-10-25 from 45a290e3. Original `researched` date retained.
DESIGN-R2 approval is recorded in EXECUTOR-APPROVALS.md at 9ce9fdc6.
Size owners were checked against the U8 ledger; see [refresh audit](../../../refresh/MP-R2-C4-T04.md).

| Fact | Evidence at the refreshed head |
| --- | --- |
| Provider behavior now implemented: capability_ids/0, capabilities/1, optional sections/1 | `src/lib/aiur/capabilities/provider.ex:1-11` |
| Registry, entry validation and run-shape collection | `src/lib/aiur/capabilities.ex`; `src/lib/aiur/capabilities/` |
| Current provider registration | `src/config/config.exs` (`:capability_providers`) |
| Identity dependency and run shape | `src/lib/aiur/identity.ex:23-60` |
| Proposed export capability | events contract §3 and §10; no exporter/provider exists yet |

PROPOSED: events export provider. Register through the existing provider interface; absence of capability code in the original research is no longer true.

## Chosen design

`capability_ids/0` → `["events.export"]`.

`capabilities(context)`:

| Condition | Entry |
| --- | --- |
| `events.export.enabled: false` | `%{state: "unavailable", reason: "disabled"}` |
| enabled, `context.no_dashboard == true` (no HTTP listener, so no API) | `%{state: "unavailable", reason: "not_running"}` |
| enabled, exporter process not alive | `%{state: "unavailable", reason: "not_running"}` |
| enabled, exporter reports corrupt journal (`Aiur.Events.Export.status/0 == {:error, :events_unavailable}`, C6-T02) | `%{state: "degraded", reason: "journal_corrupt"}` |
| enabled and healthy | `%{state: "available", version: 1, v: 1, retention: %{max_age_s: …, max_records: …}, head_seq: n}` |

- `retention` echoes the configured values from C6-T01 (KQ-R2-1 decides the
  defaults; this ticket only reports what is configured).
- `journal_corrupt` is in the identity contract's reason enum (§2.2, accepted in
  Phase D, CR-R2-4). An instance without `instance_id` reports
  `dependency_unavailable` with `depends_on: ["identity"]`.
- The registry recomputes on its tick; the provider must be cheap: one
  app-env read, one `Process.whereis`, one ETS/`persistent_term` read of
  exporter status (C6 must keep status readable without a GenServer call;
  if C6 only offers a call, use a 100 ms timeout and report `unknown`).

## Implementation steps

1. Add `src/lib/aiur/events/capability_provider.ex`.
2. Append it to `:capability_providers` in `src/config/config.exs`.
3. Add `events.export` to the `packages/aiur-contracts` ID enum if
   MP-R1-C3-T06 has landed.
4. Tests below.

## Non-happy paths

- Exporter status call times out → `unknown` with `reason: "not_running"`
  not claimed; never `available`.
- Disabled is `unavailable/disabled`, never absent: absence would mean
  "not installed", which is false for this build.
- Missing `instance_id` does not affect this capability (identity's own row).

## Compatibility and rollout

Additive; no config change. With export disabled (default) the report gains
one `unavailable/disabled` row. Rollback: remove the provider from config.

## Verification

`src/test/aiur/events/capability_provider_test.exs`:

1. `"disabled export is unavailable/disabled"` — default config.
2. `"enabled but no dashboard is unavailable/not_running"`.
3. `"enabled and healthy reports v and retention"` — start a fake exporter
   status; assert `%{"state" => "available", "v" => 1, "retention" => %{...}}`.
   **Fails if the provider returns available without checking the process**
   (mutation: return the healthy entry unconditionally → tests 2 and 4 fail).
4. `"corrupt journal is degraded, not available"`.
5. Registry integration (after MP-R1-C3): `GET /api/v1/capabilities`
   contains `capabilities["events.export"]`.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/capability_provider_test.exs test/aiur_web/controllers/capabilities_controller_test.exs
```

(The second file is MP-R1-C3-T03's; run it if present.)

Mutation check: replace the exporter-alive check with `true` → tests 2/4
fail; restore → pass. Clean worktree.

## Completion and handoff

- [ ] Provider registered; tests 1–4 added and mutation-checked.
- [ ] Docs: the capability ID table that MP-R1-C3-T07 writes in
      `website/docs-app/concepts/` gets an `events.export` row (meaning,
      reasons). If that page does not exist yet, add the row to C4-T04's
      plan-refresh list instead of creating a page.
- [x] CONTRACT-REQUESTS: `journal_corrupt` reason (to MP-R1) — accepted in Phase D.
- Dependents: MP-N3 (instance card shows feed availability), MP-N4/N5
  (daemon-side, read the same status).
