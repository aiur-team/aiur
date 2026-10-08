---
ticket_id: MP-N5-C1-T01
feature_id: MP-N5
chunk_id: MP-N5-C1
bucket: 3-mobile-watch
title: Notification preference schema v1 and machine-store file
status: ready
blocked_by: [DESIGN-N5 (no-UI release; D-2 and D-4 gate only the `Defaults` constants, step 3), MP-N4-C3-T00, MP-N2-C1-T01, MP-N2-C1-T02]
prior_units: []
prior_boundaries: [new #41 candidate push-relay (notification-policy module set)]
prior_features: [MP-N2, MP-N4]
prior_findings: [D18, RC-03, alerts.* is local sound only (config/schema/alerts.ex:13-25)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C1-T01 — Preference schema and store file

## Identity and outcome

Bucket 3, MP-N5, chunk C1. Deliver `Aiur.Push.Preferences` (PROPOSED,
`src/lib/aiur/push/preferences.ex`): the v1 preference record per paired device, its
validation, D18 defaults, and read/write of `notification-preferences.json` in the machine
store directory `${XDG_CONFIG_HOME:-~/.config}/aiur/machine/` (beside `devices.json`).
Writes go only through the MP-N2 gateway's single-writer primitives (temp + fsync +
rename under the store lock); instance daemons read with an mtime cache.

Non-goals: effective resolution (C1-T02), HTTP API (C1-T03), seeding (C1-T04), per-instance
blocker mute (C1-T05, blocked on DESIGN-N5 D-1).

## Dependencies and blockers

- MP-N2-C1-T01/T02 (store layout, atomic writes, lock). MP-N4-C3-T00 (module path).
- DESIGN-N5 header: "The preference store and policy engine (MP-N5-C1 API, C2, C3 logic)
  may proceed" — no-UI release.
- Owner defaults pending in DESIGN-N5 (D-4 non-blocking Commands on by default; D-8 queue
  milestones share the build-order setting) are **constants** in `Defaults`; the schema is
  the same for either answer (D-8 "own toggle" would add one optional field later).

## Verified starting point

- Only local sound preferences exist: `Aiur.Config.Schema.Alerts`
  (`src/lib/aiur/config/schema/alerts.ex:13-25`: `enabled`, `use_os_default_sounds`,
  `sound_dir`, `alerts_file`). Not reused: per-instance workflow config vs per-device
  machine-level preferences (MP-N5 plan §7).
- Machine store (pairing contract §5): directory 0700, files 0600, gateway single writer,
  instances read, CLI may write when the gateway is down under the launcher lock pattern.
- RC-03: machine-level data lives outside `~/.aiur/config`.

## Chosen design

```json
{ "schema": "aiur.notification-preferences/1",
  "devices": {
    "<device_id>": {
      "version": 3, "updated_at": "…",
      "defaults": {
        "commands_needs_you": "on",
        "commands_non_blocking": "on",
        "commands_reminder_minutes": 30,
        "progress_step_pct": 25,
        "progress_completion": true,
        "pr_merged": false,
        "optin": { "agent_retry_exhausted": false, "ci_failed": false } },
      "instance_overrides": { "<instance_id>": { "progress_step_pct": 50 } } } } }
```

- `commands_needs_you` accepts only `"on"` in v1 (locked on, D18); D-1 mute is C1-T05.
- `progress_step_pct ∈ {0 (off), 10, 25, 50}`; default 25 (D18, RC-10).
- Overrides keyed by `instance_id` (RC-02); partial objects; unknown keys rejected on write,
  ignored on read (forward compatibility with a newer gateway).
- `version` per device: monotonically increasing; writes require `expected_version`.
- `commands_reminder_minutes ∈ {0 (off), 15, 30, 60}`; proposed default 30 (Phase D
  feasibility M3; owner choice DESIGN-N5 D-2 / OQ-N5-2). Read by MP-N5-C2-T02.
- `Defaults` module holds D18 values plus the three pending owner values (D-2 reminder,
  D-4 non-blocking, D-8 queue milestones).
- One file for all devices; per-device sections keep concurrent edits independent
  (each device edits only its own record).

## Implementation steps

1. `preferences.ex` (struct, `validate/1`, `defaults/0`), `preferences/file.ex` (read with
   mtime cache; `write(device_id, record, expected_version)` delegating to the MP-N2 store
   writer).
2. Tests with temp `XDG_CONFIG_HOME`.
3. **Gated on DESIGN-N5 D-2 and D-4 (Phase D T-10):** the `Defaults` constants
   `commands_non_blocking` and `commands_reminder_minutes` ship with the proposals above
   and a `# set by DESIGN-N5 D-4` / `D-2` marker. This ticket may merge before the
   answers only if the PR states that the two constants are provisional; the ticket is
   not complete until they equal Kevin's answers.

## Non-happy paths

- File missing → every device has defaults (no write at read time).
- Corrupt file → reads return `{:error, :preferences_corrupt}`; policy falls back to D18
  defaults for Commands only (blocker notifications never stop because of a bad file),
  progress and opt-ins suppressed; capability `push` shows `degraded` reason `unknown`
  (C2 reports it).
- Version conflict → `{:error, {:version_conflict, current}}`.
- Device row deleted from `devices.json` → its preference section is removed by the
  gateway in the same revoke write (requested from MP-N2, CR-N5-2).

## Compatibility and rollout

New file; `schema` versioned. Rollback: file ignored by older releases.

## Verification

`src/test/aiur/push/preferences_test.exs` (PROPOSED), temp XDG only (AGENTS.md "Reading
real state"):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"missing file yields D18 defaults"` | step 25, completion true, pr_merged false, commands on | default `pr_merged: true` |
| `"commands_needs_you cannot be turned off in v1"` | `{:error, …}` for `"off"` | accept any string |
| `"step must be one of 0,10,25,50"` | 30 rejected | no enum check |
| `"reminder minutes must be one of 0,15,30,60"` | 45 rejected; missing → default | no enum check |
| `"stale expected_version is a conflict"` | conflict with current | last-writer-wins |
| `"unknown override key rejected on write, ignored on read"` | both behaviours | symmetric handling |
| `"corrupt file never suppresses Command notifications"` | `effective_commands/1` → on | propagate error to policy |

Commands: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/push/preferences_test.exs`.

## Completion and handoff

- [ ] Schema doc block in moduledoc; D-2/D-4/D-8 constants marked "set by DESIGN-N5" and
  equal to Kevin's answers before completion (T-10: `status: ready` here means
  "researched; waiting on blocked_by").
- Docs: none user-facing here (C5-T01 guide).
- Dependents: C1-T02, C1-T03, C1-T04, C1-T05, C2-*.
