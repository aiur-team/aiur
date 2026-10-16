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
