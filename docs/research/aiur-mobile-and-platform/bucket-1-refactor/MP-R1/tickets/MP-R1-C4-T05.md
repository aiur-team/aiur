---
ticket_id: MP-R1-C4-T05
feature_id: MP-R1
chunk_id: MP-R1-C4
bucket: 1-refactor
title: Config, env-var and state ownership in the manifest, with checker rules that every section and env var has exactly one owner
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T01]
prior_units: []
prior_boundaries: ["CFG #2"]
prior_features: [MP-R1-C10]
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C4-T05 — Ownership data and rules

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C4. Plan acceptance criterion 8 ("every
  config section has exactly one owner component in the manifest, and
  `check-config-docs.py` still passes").
- **User value:** the public component directory (C10) can say "this component is
  configured by these keys and env vars" from data the checker enforces, and a new
  section or env var cannot land without an owner.
- **Deliverable:**
  1. `owns.config` for every root section, `owns.env` for every env var name, `owns.state`
     for the `Config.Paths` public path functions, filled in `components.json`.
  2. Checker rules in `check-components.py`:
     - **O-config:** the set of root `embeds_one` section names in
       `src/lib/aiur/config/schema.ex` (parsed with the same regex
       `check-config-docs.py` uses, `EMBEDS_RE`, `check-config-docs.py:70`) plus the
       proposed `build_queue` once MP-E1 adds it, equals the disjoint union of
       `owns.config`. Root scalar fields (`max_vertical_panes`, … `schema.ex:42-50`) are
       owned by `control-cli`/`tui` per the table below.
     - **O-env:** every name in `Aiur.Env.Schema` (`src/lib/aiur/env/schema.ex`, 68
       entries at base, `{"NAME", …}` tuples) appears in exactly one `owns.env`.
     - **O-state:** every public function in `Aiur.Config.Paths` ending in `_dir`/`_path`
       is listed in exactly one `owns.state`.
  3. **RQ4 decision recorded:** sections stay literal `embeds_one` lines in the root schema.
     Ecto composes the struct at compile time and `check-config-docs.py` walks those
     lines textually (`check-config-docs.py:9-11,108-127`); generating them from a
     registry would break the docs gate and would still make the root reference every
     section module. Ownership is therefore data in the manifest, and behavioural
     coupling is removed by C4-T01..T04.
- **Non-goals:** moving section modules' files (they stay under `config/schema/` in the
  `config` component; their *docs ownership* is the feature's); changing keys.

## Dependencies and blockers

- DESIGN-R1 §1; C1-T01. Independent of C4-T01..T04.
- **Dependents:** MP-R1-C10-T01 (public `config` field), every feature adding a section
  (MP-E1 `build_queue`, MP-E6 `voice.conversation`, MP-N2 machine settings in
  `~/.aiur/machine` — RC-03: not a `.aiur/config` section, so not in O-config).

## Verified starting point (`45a290e3`)

- 20 root sections (`schema.ex:52-71`); owners from
  [component-map.md §5](../component-map.md). Split owners in that table (`polling`,
  `agent`) are resolved to **one** owner each for O-config: `polling` → orchestration
  (it defines the poll cycle; GitHub cadence keys are documented under it), `agent` →
  harness-adapters (routing/backends; concurrency keys documented there with a
  cross-reference). The split is recorded as `shared_with` (informational) in the manifest.
- Env groups at base: ambient 17, runtime 22, dev 11, github_app 5, provider_keys 4,
  dashboard 2, decision_api 2, linear 2, required 2, voice 1, webhook 1.
- `check-config-docs.py` regexes and root module constants at `:29-34,67-71`.

## Chosen design

Root-field ownership table (fields at `schema.ex:42-50`):

| Field | Owner |
|---|---|
| `max_vertical_panes`, `pre_warmed_sessions` | tui |
| `max_log_history_mb`, `debug` | telemetry |
| `prompt_file` | config |
| `executor_takeover_first_alert_hours`, `executor_takeover_continuous_alert_hours` | executor-attention |

Env ownership: by group as default (`github_app` → github, `provider_keys` → accounting,
`voice` → voice-stt, `webhook` → github-listeners, `decision_api` → commands,
`dashboard` → web-shell, `linear` → linear, `dev` → control-cli) and by name for
`runtime`/`ambient`/`required` (each name assigned explicitly; e.g. `AIUR_INSTANCE_KEY`
→ identity, `AIUR_BG_STATE_DIR` → launcher, `GITHUB_TOKEN` → github, `XDG_CONFIG_HOME`
→ config).

## Implementation steps

1. Extend schema with `owns.*` item formats and `shared_with`.
2. Fill the data (script-assisted: generate a draft by group, then hand-assign).
3. Implement O-config, O-env, O-state (stdlib Python; env names via regex
   `^\s*\{"([A-Z][A-Z0-9_]+)",` on `env/schema.ex`, cross-checked by count against the
   `.env.example` generator if it exposes one).
4. Fixtures.

## Non-happy paths

- New section added without owner → `O-config: section 'x' has no owner`.
- Section owned twice → names both components.
- Env schema format changes (regex finds 0 names) → exit 2, "matcher is broken, not the
  schema" (the `check-config-docs.py:135-136` convention).

## Compatibility and rollout

No runtime change. Rollback: revert.

## Verification

| Test | Fixture | Expected |
|---|---|---|
| `section_without_owner_fails` | schema with `embeds_one(:extra, Extra)` | exit 1 |
| `section_owned_twice_fails` | two components own `tracker` | exit 1 |
| `env_without_owner_fails` | env schema gains `{"AIUR_NEW", …}` | exit 1 |
| `zero_env_matches_is_broken_matcher` | env file rewritten without tuples | exit 2 |
| `real_tree_passes` | repo | exit 0; 20 sections, 68 env names counted |

Command: `bash scripts/test-check-components.sh` (pure Python; runs in `workflow security`)
and `python3 scripts/check-config-docs.py` (must still pass).

Mutation check: treat duplicates as allowed → `section_owned_twice_fails` fails; skip the
zero-match guard → `zero_env_matches_is_broken_matcher` fails.

## Completion and handoff

- [ ] All sections, env names and state paths owned; rules active in lint.
- [ ] RQ4 decision recorded in plan.md (done in Phase C) and CONTRIBUTING component
      section (C1-T05) mentions "new section/env var → add owner".
- [ ] Docs: none on the site (C10 renders the data).
- **Dependents:** C10-T01, MP-E1 (`build_queue` section owner), MP-E6.
