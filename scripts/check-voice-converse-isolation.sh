#!/usr/bin/env bash
# The voice_converse core must not reference the host app. Usage: [package_dir]
set -u
pkg="${1:-packages/elixir/voice_converse}"
fail=0
if grep -rnE '\bAiur(Web)?\.' "$pkg/lib"; then
  echo "voice_converse: lib/ references Aiur.*" >&2
  fail=1
fi
if grep -niE 'aiur' "$pkg/mix.exs"; then
  echo "voice_converse: mix.exs mentions aiur" >&2
  fail=1
fi
exit "$fail"
