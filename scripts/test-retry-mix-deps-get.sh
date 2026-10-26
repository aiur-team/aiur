#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/aiur-mix-deps-get-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

script="$root/scripts/retry-mix-deps-get.sh"
calls="$tmp/calls"

grep -Fq 'bash ../scripts/retry-mix-deps-get.sh make deps' "$root/.github/actions/setup-elixir/action.yml"
grep -Fq 'bash ../scripts/retry-mix-deps-get.sh $(MIX) deps.get' "$root/src/Makefile"
grep -Fq 'bash ../../../scripts/retry-mix-deps-get.sh mise exec -- mix deps.get' "$root/.github/workflows/voice-converse-standalone.yml"
grep -Fq 'bash ../scripts/retry-mix-deps-get.sh mise exec -- mix deps.get' "$root/Dockerfile"
grep -Fq 'bash ../scripts/retry-mix-deps-get.sh "${mix[@]}" deps.get' "$root/packaging/scripts/build-release.sh"
grep -Fq 'str(ROOT / "scripts/retry-mix-deps-get.sh")' "$root/scripts/audit-hex-dependencies.py"

cat >"$tmp/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$tmp/sleep"

cat >"$tmp/mix" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ -f "$CALLS" ]] && count="$(cat "$CALLS")"
count=$((count + 1))
printf '%s' "$count" >"$CALLS"
if ((count < 2)); then
  echo 'Failed to fetch record for yamerl from registry (using cache instead)' >&2
  echo ':timeout' >&2
  echo '** (Mix) Unknown package yamerl in lockfile' >&2
  exit 1
fi
echo success
SH
chmod +x "$tmp/mix"

output="$(CALLS="$calls" PATH="$tmp:$PATH" "$script" mix deps.get 2>&1)"
[[ "$(cat "$calls")" == 2 ]]
[[ "$output" == *"retrying in"* ]]
[[ "$output" == *success* ]]

cat >"$tmp/mix" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ -f "$CALLS" ]] && count="$(cat "$CALLS")"
count=$((count + 1))
printf '%s' "$count" >"$CALLS"
echo '** (Mix) Unknown package yamerl in lockfile' >&2
exit 1
SH
chmod +x "$tmp/mix"
: >"$calls"
if CALLS="$calls" PATH="$tmp:$PATH" "$script" mix deps.get >"$tmp/output" 2>&1; then
  echo "non-transient unknown package failure was retried or accepted" >&2
  exit 1
fi
[[ "$(cat "$calls")" == 1 ]]
grep -Fq "Unknown package yamerl in lockfile" "$tmp/output"

cat >"$tmp/mix" <<'SH'
#!/usr/bin/env bash
count=0
[[ -f "$CALLS" ]] && count="$(cat "$CALLS")"
count=$((count + 1))
printf '%s' "$count" >"$CALLS"
echo 'Failed to fetch record for tz from registry: :timeout' >&2
echo '** (Mix) Unknown package tz in lockfile' >&2
exit 1
SH
chmod +x "$tmp/mix"
: >"$calls"
if CALLS="$calls" PATH="$tmp:$PATH" "$script" mix deps.get >"$tmp/output" 2>&1; then
  echo "persistent registry timeout unexpectedly succeeded" >&2
  exit 1
fi
[[ "$(cat "$calls")" == 3 ]]
grep -Fq "failed after 3 attempts" "$tmp/output"

echo "mix deps.get retry tests passed"
