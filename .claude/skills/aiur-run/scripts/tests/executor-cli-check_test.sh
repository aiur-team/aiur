#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/executor-cli-check.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat > "$fixture/fake-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FAKE_CLI_MODE:-healthy}:$1" in
  healthy:__identity)
    printf 'AIUR_SESSION_PREFIX=aiur\nAIUR_INSTANCE_KEY=test-instance\nAIUR_RELEASE_NODE=aiur-test@127.0.0.1\n'
    ;;
  healthy:status)
    printf 'ISSUE STATE   TITLE\nAGENTS 0/16 (binding: none)\n'
    ;;
  healthy:agents)
    printf 'ISSUE  STATE      RUNTIME  ACTIVITY\n(no active agents)\n'
    ;;
  healthy:alerts)
    printf '{"topic":"ticket.1.agent.progress","needs_attention":false}\n'
    ;;
  widecols:__identity)
    printf 'AIUR_SESSION_PREFIX=aiur\nAIUR_INSTANCE_KEY=test-instance\nAIUR_RELEASE_NODE=aiur-test@127.0.0.1\n'
    ;;
  widecols:status)
    printf 'ISSUE     STATE          TITLE\nAGENTS  0/16 (binding: none)\n'
    ;;
  widecols:agents)
    printf 'ISSUE      STATE        RUNTIME   ACTIVITY\n(no active agents)\n'
    ;;
  widecols:alerts)
    printf '{"topic":"ticket.1.agent.progress","needs_attention":false}\n'
    ;;
  empty:status)
    ;;
  empty:agents)
    printf 'ISSUE  STATE      RUNTIME  ACTIVITY\n'
    ;;
  empty:alerts)
    ;;
  timeout:status)
    child=''
    trap 'kill "$child" 2>/dev/null || true; exit 124' TERM
    sleep 5 & child=$!
    wait "$child"
    ;;
  *)
    printf 'unexpected fake command: %s\n' "$1" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fixture/fake-cli"

cat > "$fixture/fake-tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *" has-session "*) exit 0 ;;
  *" list-panes "*) printf '%%1\n%%2\n%%3\n%%4\n%%5\n%%6\n' ;;
  *" capture-pane "*) printf 'Agents: 0/16 ← →\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fixture/fake-tmux"

cat > "$fixture/config" <<'EOF'
pre_warmed_sessions: 3
agent:
  max_concurrent_agents: 16
EOF

healthy="$(
  AIUR_CMD="$fixture/fake-cli" \
  AIUR_EXECUTOR_REPO_ROOT="$fixture" \
  AIUR_EXECUTOR_CONFIG="$fixture/config" \
  AIUR_EXECUTOR_TMUX="$fixture/fake-tmux" \
  "$script"
)"
jq -e '
  (.commands | length == 3) and
  (all(.commands[]; .answered and .non_empty and .well_formed and (.elapsed_ms >= 0) and (.first_lines | length > 0))) and
  (.pane_surface.pane_count == 6) and
  (.pane_surface.pre_warmed_sessions == 3) and
  (.pane_surface.live_agent_cap == 16) and
  (.tui_surface.attached and .tui_surface.agents_row and .tui_surface.cap_controls) and
  (.findings == [])
' <<< "$healthy" >/dev/null || fail "healthy CLI check was not clean"

# Column widths are cosmetic. A renderer that re-pads its headers must not make
# every hourly check report malformed_output forever.
widecols="$(
  FAKE_CLI_MODE=widecols \
  AIUR_CMD="$fixture/fake-cli" \
  AIUR_EXECUTOR_REPO_ROOT="$fixture" \
  AIUR_EXECUTOR_CONFIG="$fixture/config" \
  AIUR_EXECUTOR_TMUX="$fixture/fake-tmux" \
  "$script"
)"
jq -e '
  (all(.commands[]; .well_formed)) and (.findings == [])
' <<< "$widecols" >/dev/null || fail "re-padded headers were reported as malformed"

empty="$(
  FAKE_CLI_MODE=empty \
  AIUR_CMD="$fixture/fake-cli" \
  AIUR_EXECUTOR_REPO_ROOT="$fixture" \
  AIUR_EXECUTOR_CONFIG="$fixture/config" \
  AIUR_EXECUTOR_TMUX="$fixture/fake-tmux" \
  "$script"
)"
jq -e '
  ((.commands | ((map(select(.command == "alerts"))[0]) | (.answered and (.non_empty | not) and (.finding.reason == "empty_output")))) and
  (.findings | any(.reason == "empty_output" and .command == "alerts"))
  )
' <<< "$empty" >/dev/null || fail "empty response was not recorded as a finding"

timed_out="$(
  FAKE_CLI_MODE=timeout \
  AIUR_CMD="$fixture/fake-cli" \
  AIUR_META_CLI_TIMEOUT_SECONDS=1 \
  AIUR_EXECUTOR_REPO_ROOT="$fixture" \
  AIUR_EXECUTOR_CONFIG="$fixture/config" \
  AIUR_EXECUTOR_TMUX="$fixture/fake-tmux" \
  "$script"
)"
jq -e '
  ((.commands | ((map(select(.command == "status"))[0]) | (.timed_out and (.answered | not) and (.elapsed_ms >= 1000) and (.finding.reason == "timed_out")))) and
  (.findings | any(.reason == "timed_out" and .command == "status"))
  )
' <<< "$timed_out" >/dev/null || fail "timed out response was not recorded as a finding"

printf 'executor-cli-check tests passed\n'
