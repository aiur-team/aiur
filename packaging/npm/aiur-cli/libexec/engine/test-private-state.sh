# Private state directories owned by a --test/--test3 daemon instance.
cleanup_test_private_dir() {
  local path="$1" expected_prefix="$2" ticket_ids="$3" basename recorded_ids
  [ -n "$path" ] && [ -n "$ticket_ids" ] || return 0
  basename="${path##*/}"
  case "$basename" in
    "$expected_prefix".*) ;;
    *) return 0 ;;
  esac
  [ -f "$path/.aiur-test-private" ] || return 0
  recorded_ids="$(cat "$path/.aiur-test-private" 2>/dev/null || true)"
  [ "$recorded_ids" = "$ticket_ids" ] || return 0
  # The budget dir holds a copy of the agent token; drop it before anything else.
  rm -f -- "$path/agent-token" 2>/dev/null || true
  rm -rf -- "$path" 2>/dev/null || true
}

cleanup_test_private_state() {
  [ -n "${AIUR_RECORD_TEST_TICKET_IDS:-}" ] || return 0
  cleanup_test_private_dir "${AIUR_RECORD_TEST_STATE_DIR:-}" "aiur-test-state" "$AIUR_RECORD_TEST_TICKET_IDS"
  cleanup_test_private_dir "${AIUR_RECORD_GITHUB_BUDGET_DIR:-}" "aiur-test-budget" "$AIUR_RECORD_TEST_TICKET_IDS"
}

# The same dirs, named by the launch env instead of the instance record: the
# foreground trap and the BEAM-death watchdog run when the daemon is killed by
# PID or socket, where no `aiur stop` ever reads the record (#4648).
cleanup_test_launch_private_state() {
  [ -n "${AIUR_DEV_TEST_TICKET_IDS:-}" ] || return 0
  cleanup_test_private_dir "${AIUR_DEV_TEST_STATE_DIR:-}" "aiur-test-state" "$AIUR_DEV_TEST_TICKET_IDS"
  cleanup_test_private_dir "${AIUR_GITHUB_BUDGET_DIR:-}" "aiur-test-budget" "$AIUR_DEV_TEST_TICKET_IDS"
}

# Launch-time backstop for a sandbox whose launcher was SIGKILLed or crashed
# before any trap ran: no age gate, because the budget dir holds a token copy.
# A marked dir of ours is kept only while its launcher pid lives or a live
# process names it in its environment (a --bg BEAM, its watchdog, agents).
# ponytail: the environ probe needs /proc; elsewhere only the launcher pid and
# the 24h sweep_stale_tmp_artifacts guard it.
sweep_orphan_test_private_dirs() {
  local path pid holder
  for path in "${TMPDIR:-/tmp}"/aiur-test-budget.* "${TMPDIR:-/tmp}"/aiur-test-state.*; do
    [ -d "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] && [ -f "$path/.aiur-test-private" ] || continue
    if [ "$path" = "${AIUR_GITHUB_BUDGET_DIR:-}" ] || [ "$path" = "${AIUR_DEV_TEST_STATE_DIR:-}" ]; then
      continue
    fi
    pid="$(cat "$path/.aiur-test-launcher" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    holder=""
    if [ -d /proc/self ]; then
      holder="$(grep -lzxF -e "AIUR_GITHUB_BUDGET_DIR=$path" -e "AIUR_DEV_TEST_STATE_DIR=$path" \
        /proc/[0-9]*/environ 2>/dev/null | head -n 1 || true)"
    fi
    [ -z "$holder" ] || continue
    rm -f -- "$path/agent-token" 2>/dev/null || true
    rm -rf -- "$path" 2>/dev/null || true
  done
}
