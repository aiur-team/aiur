#!/usr/bin/env bash
# Build a distribution-ready, stripped OTP release of aiur.
#
# Produces a self-contained `mix release` (bundles ERTS) and strips its ERTS
# executables to shrink the artifact. The release tree is relocatable: it runs
# from any unpack location with no Elixir/Erlang toolchain on PATH.
#
# Emits the absolute path of the assembled release tree on stdout. All build
# chatter goes to stderr so callers can capture the path cleanly.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
elixir_dir="$repo_root/elixir"
mix_env="${MIX_ENV:-prod}"

cd "$elixir_dir"

# Resolve how to invoke mix. CI toolchains (setup-beam) put mix on PATH
# directly; local dev provides it through mise.
if command -v mix >/dev/null 2>&1; then
  mix=(mix)
elif command -v mise >/dev/null 2>&1; then
  mix=(mise exec -- mix)
else
  echo "build-release: no mix on PATH and no mise to provide it" >&2
  exit 1
fi

MIX_ENV="$mix_env" "${mix[@]}" deps.get >&2
MIX_ENV="$mix_env" "${mix[@]}" release aiur --overwrite >&2

release_dir="$elixir_dir/_build/$mix_env/rel/aiur"
if [ ! -d "$release_dir" ]; then
  echo "build-release: release tree not found at $release_dir" >&2
  exit 1
fi

# Strip ERTS executables (R8). beam.smp alone drops ~42 MB. GNU strip uses
# --strip-debug; BSD/macOS strip uses -S. Never fail the build on a strip
# error — macOS code-signing quirks are observed in the smoke test, not here.
if strip --version 2>/dev/null | grep -qi gnu; then
  strip_flag="--strip-debug"
else
  strip_flag="-S"
fi

for bindir in "$release_dir"/erts-*/bin; do
  [ -d "$bindir" ] || continue
  for f in "$bindir"/*; do
    if [ -f "$f" ] && [ -x "$f" ]; then
      strip "$strip_flag" "$f" 2>/dev/null || true
    fi
  done
done

# Drop ERTS docs/src when present (not shipped by every OTP build).
rm -rf "$release_dir"/erts-*/doc "$release_dir"/erts-*/src 2>/dev/null || true

echo "build-release: $(du -sh "$release_dir" | cut -f1) at $release_dir" >&2
echo "$release_dir"
