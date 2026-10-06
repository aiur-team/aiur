---
ticket_id: MP-N4-C3-T01
feature_id: MP-N4
chunk_id: MP-N4-C3
bucket: 3-mobile-watch
title: Machine-level `push:` settings in ~/.aiur/machine with docs
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C3-T00, MP-N2-C3-T1, MP-N2-C3-T5]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: [MP-N2]
prior_findings: [RC-03]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C3-T01 — `push:` settings

## Identity and outcome

Bucket 3, MP-N4, chunk C3. Add the `push:` section to the machine settings file
`~/.aiur/machine` (RC-03; pairing contract §8) and its documentation:

```yaml
push:
  enabled: false               # master switch
  send_timeout_ms: 5000        # per relay request
  outbox:
    max_age_seconds: 86400     # older entries: progress/opt-ins dropped, open Commands digested (MP-N5)
  allow_loopback_relay: false  # allow http://127.0.0.1|localhost relay URLs (tests, self-hosting dev)
```

Deliverable: schema module `Aiur.Push.Settings` (PROPOSED) plugged into the MP-N2 machine
settings loader, accessors with defaults, validation errors that name the key, and a
`website/docs-app/reference/configuration.md` entry per key.

Non-goals: per-instance push config (there is none; `~/.aiur/config` and `.aiur/config`
are untouched); relay URL (comes from each device's registration, contract §7).

## Dependencies and blockers

- MP-N2-C3-T1 (machine settings schema and loader, independent of `Aiur.Workflow`).
- MP-N2-C3-T5 (docs check for `~/.aiur/machine` keys); if that check is not yet in place,
  this PR still adds the docs rows (AGENTS.md "Docs ship with the change": config key →
  `reference/configuration.md`).
- DESIGN-N4 releases C3 except setup copy (C3-T07).

## Verified starting point

- `~/.aiur/config` is the fallback workflow config (`Aiur.Workflow.resolve_config_path/1`,
  `src/lib/aiur/workflow.ex:84-93`); pairing contract §8 explains why machine keys must not
  go there. Precedent for a machine-level file: `~/.aiur/alerts`
  (`src/lib/aiur/init/alerts.ex:19-20`).
- `scripts/check-config-docs.py` enforces docs only for workflow config keys today
  (AGENTS.md "Only one row above is machine-checked"); MP-N2-C3-T5 extends it.
- The Phase B plan put `push.*` in `~/.aiur/config`; this ticket follows RC-03 instead.

## Chosen design

- Defaults as above; unknown keys under `push:` are a validation error naming the key.
- `send_timeout_ms` range 500..30_000; `max_age_seconds` 600..604_800.
- Read once at component start and on the settings file's mtime change (same mtime-cache
  rule the pairing contract uses for `devices.json`, §4.4); no restart needed to enable.
- `enabled: false` → push-relay component idles and reports `push: unavailable`,
  reason `disabled` (C3-T04).

## Implementation steps

1. `src/lib/aiur/push/settings.ex` (PROPOSED) with `NimbleOptions` schema
   (`nimble_options ~> 1.0` is a runtime dep in `src/mix.exs`).
2. Register the section with the MP-N2 loader.
3. Docs rows in `website/docs-app/reference/configuration.md` under a "Machine settings
   (`~/.aiur/machine`)" heading that MP-N2-C3 creates (add it here if absent).
4. Tests.

## Non-happy paths

- File absent → all defaults (`enabled: false`).
- Invalid value → push-relay reports `push: unavailable`, reason `not_configured`, and the
  CLI (`aiur mobile status`, MP-N2) prints the key; the daemon never crashes on it.

## Compatibility and rollout

Additive; default off. Rollback: remove the section; loader ignores nothing else.

## Verification

`src/test/aiur/push/settings_test.exs` (PROPOSED), temp HOME/XDG only:

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"absent file gives enabled false"` | defaults | default `true` |
| `"unknown key under push is rejected by name"` | `{:error, "push.foo …"}` | permissive schema |
| `"out of range timeout is rejected"` | error | drop range |
| `"does not read ~/.aiur/config"` | file there with `push: {enabled: true}` is ignored | read the wrong file |
| `"mtime change reloads"` | toggling `enabled` without restart flips the accessor | cache forever |

Docs check: `python3 scripts/check-config-docs.py` (plus the MP-N2-C3-T5 extension) and
`bash scripts/test-check-config-docs.sh`.

Commands (from `src/`): `mise exec -- mix test test/aiur/push/settings_test.exs`.

## Completion and handoff

- [ ] Four keys documented with defaults in `reference/configuration.md`.
- Dependents: C3-T02, C3-T03, C3-T04.
