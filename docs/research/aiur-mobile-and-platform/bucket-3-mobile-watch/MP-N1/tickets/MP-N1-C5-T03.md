---
ticket_id: MP-N1-C5-T03
feature_id: MP-N1
chunk_id: MP-N1-C5
bucket: 3-mobile-watch
title: "Connection diagnostics screen (per machine and instance) plus a debug-build key-state section"
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C5-T01, MP-N1-C4-T01, MP-N1-C3-T02, MP-N1-C2-T05]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2, MP-R1]
prior_findings: [RC-04, RC-15]
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C5-T03 — Diagnostics screen

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C5.
- **User value:** one screen answers "why can't I reach this machine" and "why is this button
  unavailable", with the cause, its age and the next action, so the operator does not guess.
- **Deliverable:** native screen `Diagnostics` (route registered in MP-N1-C4-T01) showing, per
  paired machine: endpoints tried with each `ProbeResult` (MP-N1-C5-T01), transport mode
  (`https` / `http_degraded`), certificate summary when available, app version vs. server
  `aiur_version` and `min_client_version`, and per instance the capability list with state,
  reason and age. Entry points: the "Diagnostics" link on every `unreachable`/`unknown` state
  and every "Why is X unavailable?" link (DESIGN-N1 surface 4–5). In **debug builds only**, a
  "Key state" section listing, per machine, whether the device auth key, access token and push
  key exist (booleans, never values) — used by DV-P9 and MP-N1-C2-T01/T02 device checks.
- **Non-goals:** fixing anything automatically; a "ping executor" action (brief N3 forbids it).

## Dependencies and blockers

- DESIGN-N1 surfaces 4–6 (layout, copy, update banners); MP-N1-C5-T01 (probe); MP-N1-C4-T01
  (route); MP-N1-C3-T02 (capability cache with `boot_id`, `revision`, ages); MP-N1-C2-T05
  (module: a `debugKeyState(machineId)` method compiled only in debug).
- Concurrent with MP-N1-C5-T02/T04.

## Verified starting point (base `45a290e3`)

- Capability report shape: `contracts/identity-and-capabilities.md` §2.2 (`aiur_version`,
  `revision`, `observed_at`, `age_ms`, `freshness`, per-capability `state`/`reason`), plus
  `boot_id` and `min_client_version` added by RC-04.
- Rendering rules: client-capability-model.md §3 (states), §8 (404 → `needs_update`).
- AGENTS.md "If a surface computes an age, it renders the age"; "a collapsed cause names the
  collapse at the source".

## Chosen design

- Data only from the probe and the capability cache; the screen issues a fresh probe on open and
  on pull-to-refresh, and renders the previous result greyed with its age while probing.
- Each row = `{subject, state, reason, observedAt, ageMs, nextActionKey}`; `nextActionKey` is a
  closed list (`retry`, `check_tailnet`, `update_app`, `update_aiur`, `scan_qr_again`,
  `ask_operator_enable_mobile`, `none`) mapped to DESIGN-N1 copy. Unknown → `none` with the
  literal kind shown.
- Debug section guarded by `__DEV__` **and** a native `#if DEBUG` / `BuildConfig.DEBUG` check, so
  a release build cannot expose it even if JS is patched.

## Implementation steps

1. `src/screens/diagnostics/DiagnosticsScreen.tsx`, row components, `nextAction.ts`.
2. Native `debugKeyState` (debug only) in the module. About 200 lines.

## Non-happy paths

No paired machines → empty state routing to pairing; probe still running → previous result with
age; revoked machine → single notice then removal (shared revoked rule).

## Compatibility and rollout

App-internal.

## Verification

Jest `src/screens/diagnostics/__tests__/DiagnosticsScreen.test.tsx` with probe fixtures:

1. `every_probe_kind_renders_its_own_reason` (one case per kind). Mutation: render every
   transport error as `unreachable` without kind → fails.
2. `unknown_kind_renders_literal_unknown_not_a_guess`.
3. `stale_result_shows_age_while_probing`. Mutation: hide the age → fails.
4. `version_mismatch_names_the_side_to_update`.
5. `debug_section_absent_in_release` — renders with `__DEV__=false` and asserts no key-state
   node; native test `DebugKeyStateTests.test_method_absent_in_release` (XCTest, Release config)
   and Kotlin `DebugKeyStateTest` (release unit-test variant).

```bash
npm --prefix packages/aiur-mobile test -- src/screens/diagnostics
```

Device: used by DV-P9 (MP-N1-C10-T02) to inspect key state after revocation.

## Completion and handoff

- [ ] Tests pass; DESIGN-N1 copy applied verbatim.
- [ ] Docs: mobile guide "Diagnostics" section listing each cause and its fix.
- [ ] Dependents: MP-N3-C4-T01 (links here), MP-N6 Command screen offline state.
