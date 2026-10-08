---
ticket_id: MP-N1-C1-T02
feature_id: MP-N1
chunk_id: MP-N1-C1
bucket: 3-mobile-watch
title: Add the path-filtered mobile-package CI workflow (Android on Linux, iOS on macOS, no signing)
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C1-T01]
prior_units: []
prior_boundaries: ["SD #35 (streamdeck-package.yml precedent)"]
prior_features: []
prior_findings: []
size_owner: n/a (new workflow file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C1-T02 — `mobile-package.yml` CI workflow

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C1.
- **User value:** every PR touching the phone app proves it still builds on both platforms,
  so a broken app is never merged unnoticed.
- **Deliverable:** `.github/workflows/mobile-package.yml` (PROPOSED) with three jobs
  (`js` checks, `android` debug assemble, `ios` simulator build), triggered only on changes
  under `packages/aiur-mobile/**` or the workflow itself; plus a fixture test that the path
  filter and trigger set are what this ticket says.
- **Non-goals:** signing, store upload, release channels (MP-N1-C8-T03); Wear OS module build
  (MP-N7-C3-T04 adds a job); watch target build (MP-N7-C2-T01 extends the iOS job).

## Dependencies and blockers

- DESIGN-N1 (feature gate); MP-N1-C1-T01 (the package must exist).
- Concurrent with MP-N1-C1-T03.

## Verified starting point (base 45a290e3)

- Precedent workflow: `.github/workflows/streamdeck-package.yml:21-43` (`pull_request.paths`
  limited to `packages/streamdeck/**` and the workflow file; concurrency group at `:48-50`;
  `permissions: contents: read` at `:52-53`).
- Actions are SHA-pinned with a version comment, e.g. `actions/checkout@de0fac2e…  # v6.0.2`
  and `actions/setup-node@48b55a01…  # v6.4.0` (`streamdeck-package.yml:72,137`). The required
  CI job `workflow-security` runs `bash scripts/test-workflow-security.sh` (`ci.yml:144-157`),
  which runs `scripts/verify-workflow-security.sh` over `.github/workflows` and rejects
  unpinned actions and dangerous triggers (fixtures in `scripts/test-fixtures/workflow-security/`,
  e.g. `unpinned-action.yml`, `pull_request_target.yml`).
- macOS runner already used: `macos-14` in `release-npm.yml:179`.
- External (accessed 2026-10-06): Expo SDK 57 needs a then-current Xcode (S22 notes Xcode 16
  for `expo-apple-targets`; Capacitor v8 needs Xcode 26, S24). **UNVERIFIED** which Xcode the
  `macos-14` image ships in October 2026; the implementer reads
  <https://github.com/actions/runner-images> for the image's Xcode list and selects
  `macos-15` (or newer) if `macos-14` lacks the Xcode version Expo SDK 57 requires
  (<https://docs.expo.dev/versions/latest/>). The choice and the cited image version go in the PR body.

## Chosen design

```yaml
name: Mobile package
on:
  pull_request:
    paths: ["packages/aiur-mobile/**", ".github/workflows/mobile-package.yml"]
  push:
    branches: [main]
    paths: ["packages/aiur-mobile/**", ".github/workflows/mobile-package.yml"]
  workflow_dispatch: {}
permissions: { contents: read }
concurrency: { group: mobile-${{ github.ref }}, cancel-in-progress: true }
jobs:
  js:       # ubuntu-latest: npm ci, typecheck, lint, test
  android:  # ubuntu-latest: setup-java 17 (temurin), npx expo prebuild --platform android --clean,
            #   ./gradlew :app:assembleDebug (in the generated android/), upload nothing
  ios:      # macos-<chosen>: npx expo prebuild --platform ios --clean, pod install,
            #   xcodebuild -workspace ios/*.xcworkspace -scheme <app> -configuration Debug
            #   -sdk iphonesimulator -destination 'generic/platform=iOS Simulator'
            #   CODE_SIGNING_ALLOWED=NO build
```

- No secrets referenced; no `pull_request_target`; every `uses:` is SHA-pinned.
- Rationale: the iOS job is the expensive one (macOS minutes), so it runs only when the
  package changes; nightly cadence is unnecessary while nothing is published.
- `timeout-minutes`: js 10, android 30, ios 45.

## Implementation steps

1. Write the workflow as above, copying SHA pins from `streamdeck-package.yml` for
   `actions/checkout` and `actions/setup-node`; pin `actions/setup-java` by SHA with a
   version comment.
2. Generated `ios/`/`android/` are produced inside the job (CNG; MP-N1-C1-T01 ignores them).
3. Add `packages/aiur-mobile/scripts/test/workflow.test.mjs` (Node `node:test`, the
   `test:package` pattern from `packages/streamdeck/package.json:10`) that parses the YAML
   with the `yaml` npm package and asserts the trigger paths and jobs.
4. Add a `test:package` script to the mobile `package.json`.

## Non-happy paths

- **Runner image lacks the required Xcode:** the job fails at prebuild/xcodebuild with the
  Xcode version message; fix is the runner label, not a skipped job.
- **Flaky Gradle download:** use `gradle/actions/setup-gradle` (SHA-pinned) caching; a failed
  download is a red build, not a retry loop.
- **Security:** no tokens, no artifact upload of builds (unsigned debug builds have no value
  and could be mistaken for releases).

## Compatibility and rollout

- Only adds a workflow; not added to required checks until the owner chooses (branch
  protection is an owner action).
- Rollback: delete the file.

## Verification

- `node --test packages/aiur-mobile/scripts/test/workflow.test.mjs`:
  - `triggers only on the mobile package and the workflow file` — asserts
    `on.pull_request.paths` equals exactly the two globs. Mutation: add `"src/**"` to the
    paths → fails.
  - `defines js, android and ios jobs without secrets` — asserts the three job ids and that
    the serialized YAML contains no `secrets.`. Mutation: add `${{ secrets.X }}` → fails.
- `bash scripts/test-workflow-security.sh` passes with the new file (it scans every workflow).
  Mutation: replace one pin with `@v6` → the guard fails.
- A draft PR touching only `packages/aiur-mobile/README.md` runs the three jobs; a PR touching
  only `src/` does not run them (observed in the PR checks list).

## Completion and handoff

- [ ] Three jobs green on a PR that changes the package.
- [ ] Workflow-security guard green.
- [ ] Runner/Xcode choice recorded in the PR body with the image version.
- **Docs:** add one line to `website/docs-app/guide/mobile.md` ("CI builds both platforms on
  every change to the package"). No CLI or config docs.
- **Dependents:** MP-N1-C8-T03 (release workflow), MP-N7-C2-T01, MP-N7-C3-T04.
