#!/usr/bin/env bash
set -euo pipefail

attempts=3
log_file="$(mktemp "${TMPDIR:-/tmp}/aiur-mix-deps-get.XXXXXX")"
trap 'rm -f "$log_file"' EXIT

for ((attempt = 1; attempt <= attempts; attempt++)); do
  if "$@" >"$log_file" 2>&1; then
    cat "$log_file"
    exit 0
  else
    status=$?
  fi

  cat "$log_file" >&2
  if ! grep -Eiq \
    'Failed to fetch record for .* from registry|registry.*(:timeout|timed out|timeout)|(:timeout|timed out|timeout).*registry|request timed out after [0-9]+ms|HTTP.*(502|503|504)|connection reset|temporary failure in name resolution|could not resolve host|network is unreachable|TLS handshake timeout' \
    "$log_file"; then
    exit "$status"
  fi

  if ((attempt < attempts)); then
    delay_seconds=$((attempt == 1 ? 5 : 20))
    echo "Hex dependency fetch hit a transient registry error (attempt $attempt/$attempts); retrying in ${delay_seconds}s" >&2
    sleep "$delay_seconds"
  fi
done

echo "Hex dependency fetch failed after $attempts attempts" >&2
exit "$status"
