# Platform packages

This directory holds the generated per-platform npm packages for aiur. Each
`aiur-cli-<target>/` (e.g. `aiur-cli-linux-x64`) bundles a self-contained OTP
release built for one OS/arch and is published as an `optionalDependency` of the
main `aiur-cli` package.

These directories are **generated, not checked in**. They are produced by:

```
node packaging/scripts/assemble-platform-package.mjs \
  --release <path-to-release-tree> --target <triple> --version <vsn>
```

where `<triple>` is one of `linux-x64`, `linux-arm64`, `darwin-x64`,
`darwin-arm64`. The release tree comes from `packaging/scripts/build-release.sh`.

Only `linux-x64`, `linux-arm64`, and `darwin-arm64` are currently **published**
and pinned by `aiur-cli`. `darwin-x64` (Intel Mac) can still be assembled
locally, but is deliberately not published — no CI runner can build its OTP
release, and a pin with no published package installs silently into a runtime
with no binary (issue #2110). The published and pinned sets are enforced to
match by `packaging/scripts/check-platform-drift.mjs`, with
`packaging/scripts/platforms.mjs` as the single source of truth.

Nothing runs at install time: the packages carry no `bin` and no install
scripts. The main `aiur-cli` package resolves the matching platform package and
execs its bundled launcher.
