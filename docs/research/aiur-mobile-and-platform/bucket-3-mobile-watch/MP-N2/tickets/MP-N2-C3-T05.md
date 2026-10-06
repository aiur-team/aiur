---
ticket_id: MP-N2-C3-T05
feature_id: MP-N2
chunk_id: MP-N2-C3
bucket: 3-mobile-watch
title: Extend check-config-docs.py so every ~/.aiur/machine key must be documented (machine: prefix)
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C3-T01]
prior_units: []
prior_boundaries: [SITE, DEV]
prior_features: [MP-R1]
prior_findings: []
size_owner: n/a (scripts)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C3-T05 — Docs checker for machine settings

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C3.
- **User value:** a new machine setting cannot merge undocumented — the one docs rule AGENTS.md
  machine-checks ("Only one row above is machine-checked") now covers the second settings file.
- **Deliverable:** `scripts/check-config-docs.py` walks a second root, `Aiur.Machine.Settings.Schema`
  under `src/lib/aiur/machine/settings/schema*`, and requires each key as inline code with the prefix
  `machine:` (for example `` `machine:transport.tls.cert_file` ``) in
  `website/docs-app/reference/configuration.md`. `scripts/test-check-config-docs.sh` gains cases.
- **Non-goals:** writing the docs entries (T01 and each key's own ticket do).

## Dependencies and blockers

DESIGN-N2 gate; MP-N2-C3-T01 (the schema tree exists). Coordinate with MP-R1-C4-T01, which may
teach the same checker about registered config sections; whichever lands second rebases.

## Verified starting point (base `45a290e3`)

- `scripts/check-config-docs.py:29-34` fixes one `SCHEMA_DIR`, `ROOT_SCHEMA`, `ROOT_MODULE`;
  `load_modules()` (`:86-105`), `collect()` (`:108-127`) and `main()` (`:130-165`) match keys as inline code anywhere in the reference.
- Guard script: `scripts/test-check-config-docs.sh` (AGENTS.md "Docs ship with the change").

## Chosen design

- Introduce `ROOTS = [Root(schema_dir, root_file, root_module, prefix="")]` and add
  `Root(machine_dir, machine_root_file, "Aiur.Machine.Settings.Schema", prefix="machine:")`.
  `module_name()` resolves short names against the root being walked.
- Why a prefix: bare keys such as `mobile.enabled` or `gateway.port` would otherwise be "documented"
  by any unrelated mention; the existing docstring makes the same argument against bare field names
  (`:9-15`). The prefix also tells readers which file the key lives in.
- If the machine root file is absent (before T01 merges) the script dies with the existing
  "expected path is missing" message — so T05 must merge with or after T01.

## Implementation steps

1. Refactor the three constants into a list; loop in `main()`; prefix keys. 2. Add test cases. ~50 lines.

## Non-happy paths

A machine key documented without the prefix → reported missing (intended). A schema module defined outside the dir → not enumerated (same rule as today).

## Compatibility and rollout

Existing `.aiur/config` behaviour unchanged (test 1). The required `lint` job runs the script already.

## Verification

`scripts/test-check-config-docs.sh` new cases (temporary fixture trees, as the script's existing cases do):

1. `"existing config keys still pass"` (run against the real tree). Future-regression guard.
2. `"undocumented machine key fails and names machine:<key>"`. *Fails without:* the second root.
3. `"machine key documented without prefix still fails"`. *Fails without:* the prefix rule.

```bash
bash scripts/test-check-config-docs.sh && python3 scripts/check-config-docs.py
```

## Completion and handoff

- [ ] Both commands pass; mutation for 2, 3 recorded.
- [ ] AGENTS.md "Docs ship with the change" table: the coordinator updates the "Only one row … is
      machine-checked" sentence to mention `~/.aiur/machine` (AGENTS.md is coordinator-owned; noted in the reply).
