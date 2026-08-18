// Single source of truth for the aiur-cli platform packages this repo builds
// and publishes. Everything that pins, builds, or publishes a platform package
// must derive from here so the published set can never drift from the pinned
// set (enforced by check-platform-drift.mjs; see issue #2110).
//
// darwin-x64 (Intel Mac) is deliberately ABSENT: no CI runner can build its
// OTP release (macos-13 hosted runners are unavailable and queue indefinitely),
// so no aiur-cli-darwin-x64 package is published. Pinning it while not
// publishing it made Intel Mac installs succeed silently into a runtime with no
// binary — the exact defect this module exists to prevent.
//
// Re-enable an Intel build only by doing BOTH of these in one change:
//   1. add "darwin-x64" to PUBLISH_TARGETS below, and
//   2. uncomment the darwin-x64/macos-13 legs in the build + smoke matrices of
//      .github/workflows/release-npm.yml
// The drift check fails unless both lists agree, so a half-applied re-enable is
// caught before a release.
export const PUBLISH_TARGETS = ["linux-x64", "linux-arm64", "darwin-arm64"];
