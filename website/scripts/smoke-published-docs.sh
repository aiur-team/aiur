#!/usr/bin/env bash
# Post-deploy smoke check for the published docs site (https://aiur.team/docs/).
#
# The docs are deployed by Netlify on push to main, so this script runs from
# the push-to-main website workflow right after the docs build and compares the
# freshly built pages (dist/docs) against the live site. It fails when the
# published site does not return 200 or when its content lags the merged
# commit — the silent-stale failure mode from #1921, where a broken deploy hook
# kept serving an old build for days with no signal.
#
# Freshness is decided by the VitePress content hash map (__VP_HASH_MAP__),
# which maps every source page to a content hash. Comparing the whole map means
# the check notices staleness no matter which page the merged commit changed.
#
# Usage:
#   smoke-published-docs.sh [built-page] [live-url]
#
# Environment:
#   SMOKE_POLL_TIMEOUT_SECONDS  how long to wait for the deploy to catch up
#                               (default 900)
#   SMOKE_POLL_INTERVAL_SECONDS how long between polls (default 20)

set -euo pipefail

BUILT_PAGE="${1:-dist/docs/guide/stream-deck.html}"
LIVE_URL="${2:-https://aiur.team/docs/guide/stream-deck.html}"
POLL_TIMEOUT_SECONDS="${SMOKE_POLL_TIMEOUT_SECONDS:-900}"
POLL_INTERVAL_SECONDS="${SMOKE_POLL_INTERVAL_SECONDS:-20}"

if [[ ! -f "$BUILT_PAGE" ]]; then
  echo "error: built page not found at $BUILT_PAGE (was the docs build run?)" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Print the canonical JSON form of the page's VitePress content hash map, or
# exit non-zero if the page does not carry one.
extract_hash_map() {
  python3 - "$1" <<'PY'
import json, re, sys

html = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'window\.__VP_HASH_MAP__=JSON\.parse\("((?:[^"\\]|\\.)*)"\)', html)
if not match:
    print(f"error: __VP_HASH_MAP__ not found in {sys.argv[1]}", file=sys.stderr)
    sys.exit(1)
raw = match.group(1)
# Unescape the JS string literal before parsing it as JSON. VitePress emits
# only the two escapes handled here.
raw = raw.replace("\\\\", "\\").replace('\\"', '"')
print(json.dumps(json.loads(raw), sort_keys=True))
PY
}

expected="$(extract_hash_map "$BUILT_PAGE")"

deadline=$(( $(date +%s) + POLL_TIMEOUT_SECONDS ))
attempt=0
code="000"

while :; do
  attempt=$((attempt + 1))
  code="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 30 "$LIVE_URL" || true)"

  if [[ "$code" == "200" ]]; then
    if live="$(extract_hash_map "$tmp" 2>/dev/null)"; then
      if [[ "$live" == "$expected" ]]; then
        echo "OK: $LIVE_URL serves the build from the merged commit (HTTP 200, content hash map matches)"
        exit 0
      fi
      echo "attempt $attempt: $LIVE_URL is HTTP 200 but its content lags the merged commit (hash map differs)"
    else
      echo "attempt $attempt: $LIVE_URL returned HTTP 200 but no parseable content hash map"
    fi
  else
    echo "attempt $attempt: $LIVE_URL returned HTTP $code (expected 200)"
  fi

  if [[ "$(date +%s)" -ge "$deadline" ]]; then
    echo "error: published docs site is stale or unreachable" >&2
    echo "  url: $LIVE_URL" >&2
    echo "  last http status: $code" >&2
    echo "  live content did not match the build from the merged commit within ${POLL_TIMEOUT_SECONDS}s" >&2
    exit 1
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done
