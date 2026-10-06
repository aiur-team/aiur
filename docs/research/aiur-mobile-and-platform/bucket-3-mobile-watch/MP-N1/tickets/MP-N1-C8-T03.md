---
ticket_id: MP-N1-C8-T03
feature_id: MP-N1
chunk_id: MP-N1-C8
bucket: 3-mobile-watch
title: "Manual-dispatch release-configuration CI dry run (unsigned) for iOS and Android"
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C1-T02, MP-N1-C8-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N7]
prior_findings: []
size_owner: n/a (workflow)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C8-T03 — Release dry-run workflow

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C8.
- **User value:** release-configuration breakage (minification, Release-only entitlements,
  NSE/watch target build settings) is caught in CI before the operator tries a signed local build.
- **Deliverable:** a `workflow_dispatch` (and weekly `schedule`) job added to
  `.github/workflows/mobile-package.yml` (created by MP-N1-C1-T02) that builds **Release**
  configurations unsigned: iOS `xcodebuild archive … CODE_SIGNING_ALLOWED=NO` on `macos-14`
  (the runner `release-npm.yml:179` already uses), Android `./gradlew bundleRelease` with an
  ephemeral debug keystore generated in the job. Artifacts are not uploaded anywhere.
- **Non-goals:** signing, store upload (T01, local only).

## Dependencies and blockers

MP-N1-C1-T02 (workflow file), MP-N1-C8-T01 (script reused with `--unsigned`).

## Verified starting point (base `45a290e3`)

`.github/workflows/streamdeck-package.yml` uses `schedule` + `workflow_dispatch` with a gate that
skips nights without package changes (header comments, lines 1-40); this job copies that gate
pattern so an unchanged package costs nothing.

## Chosen design

Gate: skip unless `packages/aiur-mobile/**` changed since the last successful dry run (same
approach as the Stream Deck gate). Matrix: `ios-release`, `android-release`.

## Implementation steps

Workflow job and the `--unsigned` flag in `release-local.sh`. About 60 lines of YAML.

## Non-happy paths

Hosted macOS image lacks the pinned Xcode → job fails with the selected Xcode version printed
(same rule as MP-N1-C1-T02).

## Compatibility and rollout

CI only; no repository secrets used (assert: the job has no `secrets.` references).

## Verification

A workflow-lint test `packages/aiur-mobile/scripts/__tests__/workflow.test.mjs` (`node --test`)
parses the YAML and asserts: the dry-run job exists, uses `CODE_SIGNING_ALLOWED=NO`, references no
`secrets.` (mutation: add `${{ secrets.X }}` → fails), and has the path gate.

```bash
node --test packages/aiur-mobile/scripts/__tests__/workflow.test.mjs
```

One manual `workflow_dispatch` run is green before merge; link it in the PR.

## Completion and handoff

- [ ] Green dispatch run linked. Docs: runbook mentions the dry run.
- [ ] Dependents: MP-N7-C3-T04 (adds the Wear module to the same jobs).
