---
ticket_id: MP-E1-C3-T01
feature_id: MP-E1
chunk_id: MP-E1-C3
bucket: 2-platform
title: build_queue config section, state path key and their docs
status: blocked
blocked_by: [DESIGN-E1]
prior_units: [U6]
prior_boundaries: [CLI #31]
prior_features: [MP-R1]
prior_findings: [MP-E1 F9, F11]
size_owner: "CONFIG / Configuration (config.ex 1462 lines, not edited); config/schema.ex small (provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C3-T01 — `build_queue.*` configuration

> **Plan refresh (wave 0).** Cites `45a290e3`. MP-R1-C4 later registers this
> section through its schema-registration mechanism; the section module and
> keys stay (component map §4 "own config section module and own
> `Config.Paths` key").

## Identity and outcome

- Bucket 2, MP-E1, C3, T01.
- **User value:** an operator can turn the queue off and tune its pace in
  `.aiur/config`, and every key is documented with its default.
- **Deliverable:** PROPOSED `src/lib/aiur/config/schema/build_queue.ex`
  (`Aiur.Config.Schema.BuildQueue`), embedded as `build_queue`; a
  `Config.Paths.build_queue_dir/0`; docs.

| Key | Type | Default | Bounds |
| --- | --- | --- | --- |
| `build_queue.enabled` | boolean | `true` (OQ-6) | — |
| `build_queue.reconcile_interval_seconds` | integer | 60 | 10..3600 |
| `build_queue.max_writes_per_minute` | integer | 20 | 1..60 (below GitHub's 80/min secondary limit, F11) |
| `build_queue.observation_max_age_seconds` | integer or null | null = 2 × `polling.interval_seconds` | 10..3600 |
| `build_queue.merged_open_grace_seconds` | integer | 600 | 60..86400 |

## Dependencies and blockers

- DESIGN-E1 **OQ-6** (default of `enabled`). No ticket predecessor.
  Concurrent with C1, C2.

## Verified starting point (`45a290e3`)

- Section pattern: `src/lib/aiur/config/schema/build_order.ex:1-91`
  (`embedded_schema`, `cast/3` with `empty_values: []`, `validate_number`).
- Root embedding: `config/schema.ex:52-71` (`embeds_one`) and `:180`
  (`cast_embed`); aliases at `:10-14`.
- `config/schema/polling.ex:31` `interval_seconds` default 120.
- `config/paths.ex:60-66` `decision_state_dir/0` (per instance and project,
  `:322-358`).
- Docs: `website/docs-app/reference/configuration.md:713-720` (`## build_order`
  table format); `scripts/check-config-docs.py` fails `lint` when a key is
  missing (AGENTS.md); `.aiur/examples/config.example`;
  `src/examples/workflows/{github-claude,github-codex,github-muse,linear-codex}.yaml`.

## Chosen design

- `Config.settings!().build_queue` is the only read path. A helper
  `Aiur.BuildQueue.Settings.observation_max_age_ms/1` (PROPOSED, in
  `build_queue/`) resolves the null default from `polling.interval_seconds`.
- `Config.Paths.build_queue_dir/0` → `{:ok, Path.join(decision_state_dir, "build-queue")}`
  or the same `{:error, _}`.
- The Linear example config documents `enabled` and states the queue is
  unsupported there (no label writes, `linear/tracker.ex:139-142`).

## Implementation steps

1. Schema module + embed + cast (≈ 45 lines).
2. `Config.Paths.build_queue_dir/0` (≈ 6 lines).
3. Docs: new `## build_queue` table in `configuration.md`; commented block in
   `.aiur/examples/config.example` and each workflow example (shipped
   uncommented `enabled: true` is not needed since it is the default).

## Non-happy paths

- Out-of-bounds values fail config validation with the field name (existing
  changeset error path).
- Unknown keys under `build_queue` are ignored by `cast/3` like other sections.

## Compatibility and rollout

New optional section; existing configs load unchanged. Rollback is safe: the
root changeset uses `cast/3` plus one `cast_embed` per known section
(`config/schema.ex:150-183`), so an older release ignores an unknown
`build_queue:` key (no unknown-key rejection exists in `config/schema.ex`,
`config.ex` or `workflow.ex` at base). Downgrading still needs the marker
runbook of C6-T03.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/config_test.exs` "build_queue defaults" | `enabled: true, reconcile_interval_seconds: 60, max_writes_per_minute: 20, observation_max_age_seconds: nil, merged_open_grace_seconds: 600` | the embed |
| "build_queue rejects max_writes_per_minute 0 and 61" | changeset errors | the bounds |
| `src/test/aiur/build_queue/settings_test.exs` (PROPOSED) "null max age derives 2 × polling interval" | 240 000 ms with default polling | the derivation |
| `scripts/test-check-config-docs.sh` + `python3 scripts/check-config-docs.py` | pass | the docs table |

Mutation check: drop one docs row → `check-config-docs.py` fails; remove a
bound → test 2 fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/config_test.exs test/aiur/build_queue/settings_test.exs
python3 scripts/check-config-docs.py && bash scripts/test-check-config-docs.sh
```

## Completion and handoff

- [ ] Section, path key, docs table, example templates in one PR.
- Dependents: C3-T02, C3-T03, C4-T06.
