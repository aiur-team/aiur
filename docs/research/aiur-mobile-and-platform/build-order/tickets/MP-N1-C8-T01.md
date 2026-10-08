---
ticket_id: MP-N1-C8-T01
feature_id: MP-N1
chunk_id: MP-N1-C8
bucket: 3-mobile-watch
title: "Signing and provisioning runbook plus a local signed-build script (credentials stay in the operator's keychain)"
status: blocked
blocked_by: [DESIGN-N1, OQ-N1-1, OQ-N4-1, MP-N1-C1-T02, MP-N1-C1-T03, MP-N1-C6-T01]
prior_units: []
prior_boundaries: [SITE]
prior_features: [MP-N4, MP-N7]
prior_findings: []
size_owner: n/a (script + docs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C8-T01 — Signing runbook and local release build

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C8 "Release and distribution".
- **User value:** the operator can produce signed iOS (with NSE and watch targets) and Android
  (with the Wear module) builds on their own Mac, reproducibly, without putting signing secrets
  in the repository or in CI.
- **Deliverable:**
  - `packages/aiur-mobile/scripts/release-local.sh` (PROPOSED): `ios` → `expo prebuild --clean`,
    `xcodebuild archive` + `xcodebuild -exportArchive` with an `ExportOptions.plist` template
    (method `app-store-connect` for TestFlight); `android` → `./gradlew bundleRelease` signing with
    a keystore whose path and passwords come from environment variables
    (`AIUR_ANDROID_KEYSTORE`, `AIUR_ANDROID_KEYSTORE_PASSWORD`, `AIUR_ANDROID_KEY_ALIAS`) read at
    build time. Exit non-zero and print which variable is missing.
  - Runbook page: bundle id `dev.aiur.mobile` (placeholder until OQ-N1-1), the identifiers and
    capabilities to register (app, NSE, watch app; App Group `group.dev.aiur.mobile`; keychain
    sharing; Push Notifications), upload paths (TestFlight internal, Play internal testing), and
    certificate/profile renewal.
- **Non-goals:** CI signing (explicitly not done: no secrets in GitHub Actions for this package);
  public listing metadata (T02/OQ-N1-1).

## Dependencies and blockers

- OQ-N1-1 (distribution) and OQ-N4-1 (paid Apple Developer Program and Firebase project — "the main
  mobile blocker"); MP-N1-C1-T02/T03 (build and targets), MP-N1-C6-T01 (push entitlements).
- Watch targets (MP-N7-C2-T01, MP-N7-C3-T01) are added to the same script when they land.

## Verified starting point (base `45a290e3`)

- Repo precedent for release automation: `.github/workflows/release-npm.yml` (macOS runner
  `macos-14`, `:179`) and `.github/workflows/streamdeck-package.yml` (channel comments at the top).
  No mobile signing exists.
- TestFlight internal testing: up to 100 internal testers without App Review for TestFlight (S18,
  <https://developer.apple.com/testflight/>, accessed 2026-10-06). Play internal testing: up to 100
  testers, "might not be subject to standard Play policy or security reviews" (S28).
- AGENTS.md "Do not commit: secrets, tokens…".

## Chosen design

Local-only signing: the operator's login keychain holds the Apple distribution certificate
(Xcode automatic signing with the team id passed as `DEVELOPMENT_TEAM`), the Android upload key is a
file outside the repo. The script refuses to run inside a git worktree path that would place
artifacts under tracked directories (`build/` is gitignored in the package).

## Implementation steps

1. Script with `ios|android|all` subcommands and a `--dry-run` that prints the commands.
2. `ExportOptions.plist.template`; `.gitignore` entries for `*.ipa`, `*.aab`, `*.keystore`.
3. Runbook in `website/docs-app/guide/mobile.md` (page created by MP-N1-C1-T01). About 120 lines.

## Non-happy paths

Missing variable → exit 2 naming it; expired provisioning profile → xcodebuild error surfaced with a
runbook link; keystore password wrong → Gradle error surfaced; running on Linux → `ios` refused.

## Compatibility and rollout

Script only; nothing changes for developers who do not release.

## Verification

- `packages/aiur-mobile/scripts/__tests__/release-local.test.sh` (bats-free POSIX shell test run
  by `npm run test:scripts`): `--dry-run` with all variables prints the expected commands;
  missing `AIUR_ANDROID_KEYSTORE` exits 2 with its name (mutation: remove the check → fails);
  `git check-ignore` confirms `*.keystore`, `*.ipa`, `*.aab` are ignored.

```bash
npm --prefix packages/aiur-mobile run test:scripts
```

Manual: one signed TestFlight internal build and one Play internal-testing build installed on the
MP-N1-C10 device slots; record build numbers in the PR.

## Completion and handoff

- [ ] Tests pass; two signed builds installed on devices.
- [ ] Docs: mobile guide "Building and signing a release" (the runbook).
- [ ] Dependents: MP-N1-C8-T03, MP-N1-C10-T01/T02 (release-candidate runs).
