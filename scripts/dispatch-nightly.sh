#!/usr/bin/env bash
# Run by ci.yml's `nightly trigger` job after a green main push: dispatch
# nightly-release.yml unless today's (Los Angeles) nightly is already cut. Never
# fails the CI run; nightly-release.yml's cron retries a missed dispatch.
set -uo pipefail
tag="nightly-$(TZ=America/Los_Angeles date +%Y%m%d)"
if gh api "repos/$GH_REPO/git/ref/tags/$tag" >/dev/null 2>&1; then
  echo "$tag exists; nothing to do"
elif ! gh workflow run nightly-release.yml --ref main -f sha="$GITHUB_SHA" -f dry_run=false; then
  echo "::warning::could not dispatch nightly-release.yml; the cron fallback will retry"
fi
