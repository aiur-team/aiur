---
ticket_id: MP-R2-C6-T01
feature_id: MP-R2
chunk_id: MP-R2-C6
bucket: 1 (Bucket-2-enabling, RC-09)
title: Config keys events.export.enabled, events.export.retention_days, events.export.retention_max_events with docs rows
status: ready
blocked_by: []
prior_units: [U8]
prior_boundaries: [BUS #10, CFG]
prior_features: [MP-R1 (C4 config ownership by registration)]
prior_findings: []
size_owner: CONFIG (config.ex); current facade 440 lines, tracker_settings.ex owns accessors; new export schema in a small file
base_sha: 761756f394e6783794c777668fc1a26a540e4059
researched: 2026-10-06
---

# MP-R2-C6-T01 — `events.export.*` configuration

## Identity and outcome

- **Bucket 1 (Bucket-2-enabling, RC-09), MP-R2, chunk C6.** Off by default;
  scheduled just before its first consumer (MP-N4/MP-N5).
- **User value:** an operator can turn on the export feed (needed by the
  phone/push features) and bound how much it keeps on disk.
- **Deliverable:** three keys under `events.export`, schema + validation +
  accessors, a row each in `website/docs-app/reference/configuration.md`,
  and the commented example in `.aiur/examples/config.example`.
- **Non-goals:** nothing reads the keys yet except C6-T02/T03; no CLI.

## Dependencies and blockers

- **KQ-R2-1 (DESIGN-R2 §2 S1) — satisfied.** `EXECUTOR-APPROVALS.md`
  at `9ce9fdc6` approves 7 days **or** 50,000 events, whichever is smaller,
  configurable. This ticket implements those approved defaults and bounds.
- **MP-R1-C4** registers `events.*` from the owning component (decisions:
  MP-R2-C4-T02 absorbed). This is not a blocker: either path below works, so Phase D removed the
  chunk-level `MP-R1-C4` entry from `blocked_by`. If MP-R1-C4's events ticket has landed, add the
  nested schema through that registration; otherwise add it to
  `Aiur.Config.Schema.Events` directly (today's pattern). Key names are
  identical either way.
- Concurrent with C5-*, C6-T02 (which reads these keys; merge this first).

## Verified starting point (761756f394e6783794c777668fc1a26a540e4059)

Refreshed 2026-10-25 from 45a290e3. Original `researched` date retained.
DESIGN-R2 approval is recorded in EXECUTOR-APPROVALS.md at 9ce9fdc6.
Size owners were checked against the U8 ledger; see [refresh audit](../../../refresh/MP-R2-C4-T04.md).

| Fact | Evidence at the refreshed head |
| --- | --- |
| Three existing events fields; no export embed yet | `src/lib/aiur/config/schema/events.ex:7-30` |
| Root embed and nested embed pattern | `src/lib/aiur/config/schema.ex`; `src/lib/aiur/config/schema/agent.ex` |
| Config facade delegates; settings access moved | `src/lib/aiur/config.ex:198-201`; `src/lib/aiur/config/tracker_settings.ex:116-129` |
| Documentation/checker | `website/docs-app/reference/configuration.md`; `scripts/check-config-docs.py`; `scripts/test-check-config-docs.sh` |
| Annotated examples | `.aiur/examples/config.example` |

PROPOSED: EventsExport schema and export accessors. Keep new code in small modules; existing config delegation stays the public entry point.

## Chosen design

```yaml
events:
  export:
    enabled: false              # default; the feed, route, socket and process do not exist
    retention_days: 7           # KQ-R2-1 approved
    retention_max_events: 50000 # KQ-R2-1 approved; whichever bound is hit first trims
```

- `EventsExport` embedded schema: `enabled :boolean default false`,
  `retention_days :integer default 7` (validate 1..90),
  `retention_max_events :integer default 50_000` (validate 1_000..1_000_000).
  Upper bounds keep the journal bounded on disk (at ≈ 400 bytes/record,
  1 000 000 records ≈ 400 MB; record size is measured in C6-T05).
- `Aiur.Config.Schema.Events`: `embeds_one(:export, EventsExport, on_replace: :update, defaults_to_struct: true)`
  and `cast_embed(:export, with: &EventsExport.changeset/2)`.
- Accessors: `events_export_enabled?/0`, `events_export_retention_days/0`,
  `events_export_retention_max_events/0` in `config.ex` (after the current implementation).
- **Runtime change:** read at boot only. Changing `enabled` takes a restart
  (documented in the row). Reason: the exporter's placement and `gap`
  semantics (C6-T02) assume the subscription exists for the whole boot.

## Implementation steps

1. Schema module + embed + cast in `config/schema/events.ex`.
2. Three accessors in `config.ex`.
3. Three rows in `configuration.md` under `## events`:
   - `events.export.enabled` | boolean | false | Writes allowlisted events
     to a bounded local journal for the external event feed. Restart to
     apply. When false, no journal file, route or socket exists.
   - `events.export.retention_days` | integer | 7 | Oldest exported event
     kept; older records are trimmed. Clients that were offline longer get
     a `reset` and re-read state.
   - `events.export.retention_max_events` | integer | 50000 | Maximum
     records kept; whichever retention bound is reached first applies.
4. Extend the commented example at `.aiur/examples/config.example`
   (the `aiur init` template; AGENTS.md "Docs ship with the change" names
   these templates) with `export: { enabled: false, retention_days: 7,
   retention_max_events: 50000 }`. `src/examples/workflows/*.yaml` have no
   `events:` block at base (`git grep "events:"` hit only the example), so
   they are unchanged.

## Non-happy paths

- Invalid values (0, negative, beyond bounds): config load fails with the
  key named, as every other section does (Ecto changeset error path).
- Old config without `events.export`: defaults apply (`defaults_to_struct`).
- `enabled: true` with identity unavailable: handled by C6-T02 (feed
  unavailable), not here.

## Compatibility and rollout

Additive keys, default off; existing configs load unchanged. Rollback:
revert; a config that sets the keys would then fail to load only if the
schema rejects unknown keys — check `Schema` cast behaviour at
implementation and note it in the PR body.

## Verification

1. `test/aiur/config/events_export_config_test.exs` (PROPOSED):
   `"defaults: export disabled, 7 days, 50000 events"` — parse `%{}` →
   accessors return `false, 7, 50_000`; `"rejects retention_days 0 and
   retention_max_events 999"` → changeset errors naming
   `events.export.retention_days`/`retention_max_events`. **Fails without
   step 1.**
2. `python3 scripts/check-config-docs.py` passes; **fails** if any of the
   three rows is removed (mutation).
3. `bash scripts/test-check-config-docs.sh` passes.
4. `.aiur/examples/config.example` still parses: existing example round-trip
   test (MP-R1-C4 lists one; at base use the config loading tests under
   `test/aiur/config*`).

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/config/events_export_config_test.exs
python3 scripts/check-config-docs.py && bash scripts/test-check-config-docs.sh
```

Mutation check: delete the `retention_max_events` docs row →
`check-config-docs.py` fails; revert the schema hunk → test 1 fails.

## Completion and handoff

- [x] KQ-R2-1 answered: 7 days or 50,000 events, whichever is smaller,
      configurable (`EXECUTOR-APPROVALS.md`, `9ce9fdc6`).
- [ ] Defaults match the approved answer.
- [ ] Three keys, three docs rows, example updated (AGENTS.md config-key rule;
      `check-config-docs.py` enforces the rows).
- [ ] Tests added and mutation-checked.
- Dependents: C6-T02 (enabled), C6-T03 (retention), C7-T01/T03 (feature
  disabled → 404 / capability absent).
