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
mode="${FAKE_CLI_MODE:-healthy}"
# Behave like scripts/aiurdev: AIUR_REPO_ROOT names the aiur SOURCE checkout,
# so a consumer repository injected through it breaks engine resolution before
# any daemon is reached. The instance is keyed by the cwd instead, so the probe
# must run from the target repository.
if [ "$mode" = devshim ]; then
  if [ -n "${AIUR_REPO_ROOT:-}" ]; then
    printf '%s: line 886: %s/packaging/npm/aiur-cli/libexec/aiur-engine.sh: No such file or directory\n' "$0" "$AIUR_REPO_ROOT" >&2
    exit 127
  fi
  if [ "$(pwd -P)" != "$(cd "$FAKE_CLI_EXPECT_ROOT" && pwd -P)" ]; then
    printf 'fake-cli ran from %s, not the target repository\n' "$(pwd -P)" >&2
    exit 1
  fi
  mode=healthy
fi
case "$mode:$1" in
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
  unavailable:*)
    printf '%s: line 886: /nowhere/packaging/npm/aiur-cli/libexec/aiur-engine.sh: No such file or directory\n' "$0" >&2
    exit 127
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

# #2670: the hourly audit aimed aiurdev at a consumer repository by exporting
# AIUR_REPO_ROOT, which the dev shim reads as its own source checkout. The probe
# must target the repository by running from it, must scrub an ambient
# AIUR_REPO_ROOT rather than forward one, and must keep a caller-relative
# AIUR_CMD resolvable after changing directory.
target_repo="$fixture/consumer"
mkdir -p "$target_repo"
# Ambient identity overrides are dropped so the socket assertion proves the
# `__identity` probe itself reached the fake CLI from the target repository.
devshim="$(
  cd "$fixture" &&
  env -u AIUR_SESSION_PREFIX -u AIUR_INSTANCE_KEY -u AIUR_RELEASE_NODE \
    -u AIUR_TMUX_SOCKET -u AIUR_TMUX_SESSION \
  FAKE_CLI_MODE=devshim \
  FAKE_CLI_EXPECT_ROOT="$target_repo" \
  AIUR_REPO_ROOT="$fixture/aiur-source" \
  AIUR_CMD="./fake-cli" \
  AIUR_EXECUTOR_REPO_ROOT="$target_repo" \
  AIUR_EXECUTOR_CONFIG="$fixture/config" \
  AIUR_EXECUTOR_TMUX="$fixture/fake-tmux" \
  "$script"
)"
jq -e '
  (.target.repo_root == $target) and
  (all(.commands[]; .answered and .non_empty and .well_formed and (.exit_code == 0))) and
  (.pane_surface.socket == "aiur-" + $user + "-test-instance") and
  (.findings == [])
' --arg target "$target_repo" --arg user "${USER:-$(id -un)}" <<< "$devshim" >/dev/null ||
  fail "dev-shim CLI was not probed from the target repository without AIUR_REPO_ROOT: $devshim"

# A launcher that cannot find its engine (exit 127) is a probe misconfiguration,
# not a daemon answering garbage, and the finding must say so.
unavailable="$(
  FAKE_CLI_MODE=unavailable \
  AIUR_CMD="$fixture/fake-cli" \
  AIUR_EXECUTOR_REPO_ROOT="$fixture" \
  AIUR_EXECUTOR_CONFIG="$fixture/config" \
  AIUR_EXECUTOR_TMUX="$fixture/fake-tmux" \
  "$script"
)"
jq -e '
  (all(.commands[]; .answered and .non_empty and (.well_formed | not) and (.exit_code == 127) and (.finding.reason == "command_unavailable"))) and
  ((.findings | map(select(.kind == "cli")) | length) == 3) and
  (.findings | map(select(.kind == "cli")) | all(.reason == "command_unavailable" and .exit_code == 127))
' <<< "$unavailable" >/dev/null || fail "exit 127 was not recorded as command_unavailable: $unavailable"

printf 'executor-cli-check tests passed\n'
