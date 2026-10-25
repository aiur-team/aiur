#!/usr/bin/env bash
# A nightly is worth cutting only if the packages changed. Two checks:
#   1. The nightly version embeds the head sha, so "already on the
#      registry" is exactly "main has not moved since the last nightly".
#   2. Main moving is not enough on its own: only src/ and packaging/
#      (plus the toolchain pins and this workflow) ship in these packages,
#      so a day of docs or Stream Deck commits publishes nothing. The
#      registry's `nightly` dist-tag records the last published commit.
# No change means no publish, and a no-op run is the correct outcome.
# Env: CHANNEL, VERSION.
set -euo pipefail
channel="$CHANNEL"
version="$VERSION"
if [ "$channel" != "nightly" ]; then
  echo "proceed=true" >> "$GITHUB_OUTPUT"
  exit 0
fi
if [ -n "$(npm view "aiur-cli@$version" version 2>/dev/null || true)" ]; then
  echo "aiur-cli@$version is already published; main has not moved since the last nightly"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
current=$(npm view aiur-cli dist-tags.nightly 2>/dev/null || true)
previous="${current##*-nightly.}"
if [ -n "$current" ] && [ "$previous" != "$current" ] \
  && git merge-base --is-ancestor "$previous" HEAD 2>/dev/null \
  && git diff --quiet "$previous" HEAD -- src packaging mise.toml LICENSE NOTICE .github/workflows/release-npm.yml; then
  echo "no changes under src/ or packaging/ since nightly $current ($previous); nothing to publish"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
else
  echo "cutting nightly $version (last nightly: ${current:-none})"
  echo "proceed=true" >> "$GITHUB_OUTPUT"
fi
