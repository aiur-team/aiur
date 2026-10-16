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
  rm -rf -- "$path" 2>/dev/null || true
}

cleanup_test_private_state() {
  [ -n "${AIUR_RECORD_TEST_TICKET_IDS:-}" ] || return 0
  cleanup_test_private_dir "${AIUR_RECORD_TEST_STATE_DIR:-}" "aiur-test-state" "$AIUR_RECORD_TEST_TICKET_IDS"
  cleanup_test_private_dir "${AIUR_RECORD_GITHUB_BUDGET_DIR:-}" "aiur-test-budget" "$AIUR_RECORD_TEST_TICKET_IDS"
}
