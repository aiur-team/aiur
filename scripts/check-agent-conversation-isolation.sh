#!/usr/bin/env bash
# The agent_conversation package must not reference the host application.
# Usage: check-agent-conversation-isolation.sh [package_dir]
set -u
pkg="${1:-packages/elixir/agent_conversation}"
fail=0
if grep -rnE '\bAiur(Web)?\.' "$pkg/lib"; then
  echo "agent_conversation: lib/ references Aiur.*" >&2
  fail=1
fi
if grep -nE '\bAiur(Web)?\b' "$pkg/mix.exs"; then
  echo "agent_conversation: mix.exs mentions Aiur" >&2
  fail=1
fi
if grep -rnE '\bAiur(Web)?\.' "$pkg/examples"; then
  echo "agent_conversation: examples/ references Aiur.*" >&2
  fail=1
fi
exit "$fail"
