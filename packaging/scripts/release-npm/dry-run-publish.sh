#!/usr/bin/env bash
# Dry-run channel stops here. `npm publish --dry-run` still attempts the
# OIDC exchange but swallows a failure and returns 0 (npm/cli#8525), so a
# broken trusted-publisher config would pass silently. Run it verbose and
# fail on the exchange-failure log line instead: that is currently the
# only preflight that actually proves OIDC before a real publish.
# Env: DIST_TAG.
set -euo pipefail
set -o pipefail
fail=0
# The dry-run resolves a `dev` prerelease version, and npm refuses to
# publish any prerelease without an explicit --tag. Without this the
# run dies on argument validation *before* attempting the exchange, so
# the OIDC assertion below never executes. The tag is inert here (a
# dry run publishes nothing); it exists only to get npm far enough to
# authenticate.
tag="${DIST_TAG:-dev}"
for tgz in "$GITHUB_WORKSPACE"/artifacts/aiur-cli-*/*.tgz "$GITHUB_WORKSPACE"/artifacts/launcher/*.tgz; do
  echo "::group::dry-run $(basename "$tgz")"
  npm publish "$tgz" --dry-run --tag "$tag" --access public --loglevel verbose 2>&1 | tee out.log
  echo "::endgroup::"
  if grep -q "Failed token exchange request" out.log; then
    echo "OIDC token exchange FAILED for $(basename "$tgz")" >&2
    grep -i oidc out.log >&2 || true
    fail=1
  # Absence of a failure line is not proof of success: if npm exits
  # before it ever reaches auth, nothing failed and nothing happened.
  # Require positive evidence that the exchange was attempted, or this
  # preflight silently certifies a config it never exercised.
  elif ! grep -qiE 'oidc|trusted publish' out.log; then
    echo "No OIDC exchange was attempted for $(basename "$tgz"); this preflight proved nothing." >&2
    fail=1
  fi
done
exit "$fail"
