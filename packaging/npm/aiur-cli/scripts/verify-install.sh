#!/usr/bin/env bash
#
# Pre-release install verification — proves the published artifact installs and
# runs WITHOUT publishing to the registry. Run before cutting a release.
#
#   Layer 1  the packed `aiur-cli` (bin/aiur.js + engine) runs a release passed
#            via AIUR_RELEASE_DIR — exercises the exact `files` allowlist.
#   Layer 2  a platform package carrying a release/ is resolved by bin/aiur.js
#            with no AIUR_RELEASE_DIR — exercises resolveReleaseDir().
#
# Usage: verify-install.sh [<real-release-dir>]
#   <real-release-dir> defaults to the repo's local dev release.
set -euo pipefail

cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$cli_dir/../../.." && pwd)"
release_dir="${1:-$repo_root/src/_build/dev/rel/aiur}"

[ -x "$release_dir/bin/aiur" ] || {
  echo "❌ no release at $release_dir (run: scripts/aiurdev build)" >&2
  exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/aiur-verify.XXXXXX")"
trap 'rm -rf "$work"' EXIT
echo "▶ workdir: $work"

# --- Layer 1: packed CLI + engine -------------------------------------------
echo "▶ Layer 1: pack + install aiur-cli, run with AIUR_RELEASE_DIR"
cli_tgz="$(cd "$cli_dir" && npm pack --silent --pack-destination "$work")"
cli_tgz="$work/$cli_tgz"

prefix1="$work/l1"
mkdir -p "$prefix1"
npm install --silent --no-audit --no-fund --prefix "$prefix1" "$cli_tgz" >/dev/null 2>&1 || true
aiur_bin="$prefix1/node_modules/.bin/aiur"
[ -x "$aiur_bin" ] || {
  echo "  ❌ Layer 1: installed aiur bin not found at $aiur_bin" >&2
  exit 1
}

out="$(AIUR_RELEASE_DIR="$release_dir" "$aiur_bin" --version 2>&1)" || true
echo "  --version -> $out"
case "$out" in
  aiur\ *) echo "  ✅ Layer 1 passed (packed CLI + engine ran the release)" ;;
  *)
    echo "  ❌ Layer 1 failed: $out" >&2
    exit 1
    ;;
esac

# --- Layer 2: platform-package resolution -----------------------------------
echo "▶ Layer 2: fake platform package, resolve with no AIUR_RELEASE_DIR"
triple="$(node -e 'const m={"darwin arm64":"darwin-arm64","darwin x64":"darwin-x64","linux arm64":"linux-arm64","linux x64":"linux-x64"};process.stdout.write(m[`${process.platform} ${process.arch}`]||"")')"
[ -n "$triple" ] || { echo "  ⚠ unsupported platform; skipping Layer 2" >&2; exit 0; }

plat="$work/platform"
mkdir -p "$plat/release/releases/0.0.0" "$plat/release/bin"
printf '{\n  "name": "aiur-cli-%s",\n  "version": "0.0.0",\n  "files": ["release"]\n}\n' "$triple" >"$plat/package.json"
printf '16.4 0.0.0\n' >"$plat/release/releases/start_erl.data"
printf '#!/usr/bin/env bash\necho "STUB_RELEASE"\n' >"$plat/release/releases/0.0.0/elixir"
chmod +x "$plat/release/releases/0.0.0/elixir"
printf '#!/usr/bin/env bash\necho "STUB_BIN"\n' >"$plat/release/bin/aiur"
chmod +x "$plat/release/bin/aiur"
plat_tgz="$(cd "$plat" && npm pack --silent --pack-destination "$work")"
plat_tgz="$work/$plat_tgz"

prefix2="$work/l2"
mkdir -p "$prefix2"
npm install --silent --no-audit --no-fund --prefix "$prefix2" "$cli_tgz" "$plat_tgz" >/dev/null 2>&1 || true
aiur_bin2="$prefix2/node_modules/.bin/aiur"
[ -x "$aiur_bin2" ] || { echo "  ❌ Layer 2: installed aiur bin not found" >&2; exit 1; }

# __identity prints the AIUR_RELEASE_DIR bin/aiur.js resolved.
out2="$("$aiur_bin2" __identity 2>&1 || true)"
resolved="$(printf '%s\n' "$out2" | sed -n 's/^AIUR_RELEASE_DIR=//p')"
echo "  resolved release dir -> $resolved"
case "$resolved" in
  */node_modules/aiur-cli-"$triple"/release) echo "  ✅ Layer 2 passed (resolved the platform package's release)" ;;
  *) echo "  ❌ Layer 2 failed: resolved '$resolved'" >&2; exit 1 ;;
esac

echo "✅ Both layers passed — the packed artifact installs and runs. Publishing is mechanical."
