#!/usr/bin/env bash
# The voice_transcribe package must not reference the host app, Phoenix, or the
# Stream Deck sidecar. Usage: [package_dir]
set -u
pkg="${1:-packages/elixir/voice_transcribe}"
fail=0
if grep -rnE '\bAiur(Web)?\.' "$pkg/lib"; then
  echo "voice_transcribe: lib/ references Aiur.*" >&2
  fail=1
fi
if grep -rnE '\bPhoenix\b' "$pkg/lib"; then
  echo "voice_transcribe: lib/ references Phoenix" >&2
  fail=1
fi
if grep -rniE 'streamdeck|stream_deck' "$pkg/lib"; then
  echo "voice_transcribe: lib/ references Stream Deck" >&2
  fail=1
fi
if grep -niE 'aiur' "$pkg/mix.exs"; then
  echo "voice_transcribe: mix.exs mentions aiur" >&2
  fail=1
fi
exit "$fail"
