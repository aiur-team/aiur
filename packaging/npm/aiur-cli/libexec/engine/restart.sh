# Stop, refresh the release, and start again. Sourced by aiur-engine.sh.
# Stop, refresh the release, start again — `aiur restart`.
#
# Refresh runs between stop and start because a dev rebuild rewrites the release
# in place. The dev shim supplies the build-if-stale step; installed aiur has no
# source tree and performs a plain bounce.
aiur_restart_daemon_state="untouched"
aiur_restart_phase="idle"
aiur_restart_reason=""
aiur_restart_keep_agents=0

aiur_write_restart_diagnostic() {
  [ "$aiur_restart_keep_agents" -eq 1 ] || return 0
  local path tmp
  path="$(aiur_restart_diagnostic_path)" || return 0
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
  tmp="$(mktemp "${path}.XXXXXX" 2>/dev/null)" || return 0
  {
    printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf 'handoff_id=%s\n' "${AIUR_RESTART_HANDOFF_ID:-unknown}"
    printf 'phase=%s\n' "$aiur_restart_phase"
    printf 'reason=%s\n' "${aiur_restart_reason:-none}"
    printf 'daemon_state=%s\n' "$aiur_restart_daemon_state"
    printf 'startup_attempted=%s\n' "${aiur_restart_start_attempted:-0}"
    local crash_marker crash_evidence
    crash_marker="$(aiur_crash_marker_path)"
    if [ -s "$crash_marker" ]; then
      printf 'unexpected_exit_evidence_begin\n'
      sed 's/^/  /' "$crash_marker"
      printf 'unexpected_exit_evidence_end\n'
    else
      crash_evidence="$(aiur_restart_crash_evidence_path)"
      if [ -s "$crash_evidence" ]; then
        printf 'unexpected_exit_evidence_begin\n'
        sed 's/^/  /' "$crash_evidence"
        printf 'unexpected_exit_evidence_end\n'
      fi
    fi
  } >"$tmp" || { rm -f "$tmp"; return 0; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# Keep the failure trap armed through confirmed start so a failed rebuild,
# missing tmux, boot failure or interruption cannot sound harmless.
aiur_restart_report_state() {
  [ "$aiur_restart_daemon_state" = "stopped" ] || return 0
  aiur_write_restart_diagnostic

  # release_dir is resolved by the stop; fall back to the caller's declared dir
  # for the paths that fail before that.
  local dir="${release_dir:-${AIUR_RELEASE_DIR:-}}"

  echo "aiur: the daemon is STOPPED and was NOT restarted" >&2
  if [ -n "${AIUR_RESTART_HANDOFF_ID:-}" ]; then
    if [ "${aiur_restart_start_attempted:-0}" -eq 1 ]; then
      echo "aiur: handoff $AIUR_RESTART_HANDOFF_ID; startup was attempted, so provider survival is unknown. Inspect 'aiur status --handoff --json' after recovery." >&2
    else
      echo "aiur: handoff $AIUR_RESTART_HANDOFF_ID and providers retained until the configured relay orphan timeout (default 30 minutes); start aiur to adopt." >&2
    fi
  fi
  if [ -n "$dir" ] && [ -x "$dir/bin/aiur" ]; then
    echo "aiur: fix the cause and run 'aiur restart' again, or 'aiur restart --no-build' to start" >&2
    echo "      on the release already on disk" >&2
  else
    # The dev builder removes an incomplete release, so after a failed rebuild
    # there is nothing for --no-build to start. Advertising it anyway would cost
    # the operator a second failed cycle while the fleet stays down.
    echo "aiur: no complete release is left on disk, so --no-build has nothing to start —" >&2
    echo "      fix the build and run 'aiur restart' again" >&2
  fi
}

# The rebuild runs in a process this command cannot see into, so "the builder
# exited 0" is not the same claim as "the release I am about to boot is the one
# it just built" — a wrapper pointed at another checkout satisfies the first and
# not the second, which is exactly how a bounce ships a stale release while every
# step reports success. The builder leaves a receipt naming the release dir it
# vouches for and the commit it built from; this checks both against the release
# on disk. Anything unverifiable is reported as unverifiable, never as success.
verify_restart_build() {
  local receipt="$1"
  local built_dir built_sha stamped_sha stamp target_dir

  if [ ! -s "$receipt" ]; then
    echo "aiur: the rebuild left no build receipt, so restart cannot confirm which" >&2
    echo "      release it produced" >&2
    return 1
  fi

  built_dir="$(sed -n 's/^release_dir=//p' "$receipt" | head -n 1)"
  built_sha="$(sed -n 's/^source_sha=//p' "$receipt" | head -n 1)"

  # Fail on the missing field rather than on whatever an empty one happens to
  # compare equal to further down.
  if [ -z "$built_dir" ] || [ -z "$built_sha" ]; then
    echo "aiur: the build receipt is malformed; restart cannot confirm what was built" >&2
    return 1
  fi

  # Compare canonical paths: the builder and this engine can reach the same
  # release through different symlinked parents.
  built_dir="$(cd -P "$built_dir" 2>/dev/null && pwd || printf '%s' "$built_dir")"
  target_dir="$(cd -P "${AIUR_RELEASE_DIR:-}" 2>/dev/null && pwd || printf '%s' "${AIUR_RELEASE_DIR:-}")"

  if [ "$built_dir" != "$target_dir" ]; then
    echo "aiur: the rebuild targeted a different release than the one about to boot" >&2
    echo "      rebuilt : $built_dir" >&2
    echo "      booting : $target_dir" >&2
    return 1
  fi

  stamp="$target_dir/AIUR_BUILD_STAMP"
  if [ ! -r "$stamp" ]; then
    echo "aiur: the release carries no build stamp, so restart cannot confirm it is" >&2
    echo "      the one just built ($stamp)" >&2
    return 1
  fi

  stamped_sha="$(sed -n 's/^source_sha=//p' "$stamp" | head -n 1)"
  if [ "$stamped_sha" != "$built_sha" ]; then
    echo "aiur: the release on disk was not built from the commit the rebuild reported" >&2
    echo "      rebuild reported : $built_sha" >&2
    echo "      release stamped  : $stamped_sha" >&2
    return 1
  fi

  # Say what was actually established. "verified ... built from unknown" would be
  # a silent-pass guard reporting success over a release it cannot identify, and
  # a dirty tree means the SHA is a floor rather than an identity.
  if [ "$stamped_sha" = "unknown" ]; then
    echo "aiur: release $target_dir matches the rebuild, but its source commit is" >&2
    echo "      unknown (built outside a git work tree) — provenance unverified" >&2
    return 0
  fi

  if [ "$(sed -n 's/^dirty=//p' "$stamp" | head -n 1)" = "yes" ]; then
    echo "aiur: release $target_dir built from $stamped_sha with uncommitted changes" >&2
    return 0
  fi

  echo "aiur: verified release $target_dir built from $stamped_sha" >&2
}

cmd_restart() {
  local skip_build=0 keep_agents=0 arg
  AIUR_RESTART_HANDOFF_ID="" aiur_restart_start_attempted=0
  local run_args=()

  # Refuse a stale config before stopping a healthy daemon. dispatch_run also
  # checks this for ordinary launches, but restart mutates state before it gets
  # that far.
  reject_legacy_config "$@"

  for arg in "$@"; do
    case "$arg" in
      --no-build) skip_build=1 ;;
      --keep-agents) keep_agents=1 ;;
      *) run_args+=("$arg") ;;
    esac
  done

  aiur_restart_keep_agents="$keep_agents"
  if [ "$keep_agents" -eq 1 ]; then
    aiur_restart_phase="preflight"
    aiur_restart_reason="preflight_started"
    rm -f "$(aiur_restart_crash_evidence_path)" 2>/dev/null || true
    aiur_write_restart_diagnostic
    prepare_restart_handoff
    aiur_restart_phase="preflight_complete"
    aiur_restart_reason="handoff_prepared"
    aiur_write_restart_diagnostic
  fi

  local previous_sha="unknown" snapshot_dir=""
  if [ -n "${AIUR_RESTART_BUILD_CMD:-}" ] && [ "$skip_build" -eq 0 ]; then
    restart_release_snapshot "${AIUR_RELEASE_DIR:-}" || die "restart aborted before stop: could not preserve the previous release"
    previous_sha="${RESTART_PREVIOUS_SHA:-unknown}"
    snapshot_dir="${RESTART_SNAPSHOT_DIR:-}"
  fi

  # Restarting something that is already down is a start, not an error: the
  # operator asked for a running daemon on current code, and that is what they
  # get. Any OTHER stop failure is fatal — building and starting on top of a
  # half-stopped instance is the in-place rewrite this ordering exists to avoid.
  local stop_status=0
  cmd_stop || stop_status=$?
  if [ "$stop_status" -ne 0 ]; then
    if [ "${AIUR_STOP_FOUND_NOTHING:-0}" -eq 1 ]; then
      echo "aiur: nothing was running; restart will start a fresh session" >&2
    else
      die "restart aborted: stop failed (exit $stop_status); the daemon may still be running"
    fi
  fi

  # cmd_stop's tmux teardown is best-effort (`|| true`), so a stop can report
  # success while the session survives. Starting from there would rebuild the
  # release under a live BEAM and then hit run_session's idempotent "already
  # running" return — exit 0, stale release, no bounce. Refuse instead.
  # release_bin is unset only when the stop was stubbed out, i.e. in tests.
  if [ -n "${release_bin:-}" ] && [ "$(probe_control_liveness)" = "up" ]; then
    die "restart aborted: the previous session still answers after the stop; nothing was rebuilt or restarted"
  fi

  aiur_restart_daemon_state="stopped"
  aiur_restart_phase="daemon_stopped"
  aiur_restart_reason="stop_completed"
  aiur_write_restart_diagnostic
  trap aiur_restart_report_state EXIT INT TERM

  # TERM can end the BEAM process just before epmd releases its node name.
  # Wait here before an in-place release rebuild or a new distribution boot.
  if [ -n "${release_bin:-}" ] && ! wait_for_node_name_release "${AIUR_RELEASE_NODE}"; then
    aiur_restart_phase="node_name_wait_failed"
    aiur_restart_reason="old_node_name_not_released"
    die "restart aborted: node name ${AIUR_RELEASE_NODE} is still registered; nothing was rebuilt or restarted"
  fi

  aiur_restart_phase="rebuild"
  aiur_restart_reason="rebuild_started"
  aiur_write_restart_diagnostic

  if [ -n "${AIUR_RESTART_BUILD_CMD:-}" ] && [ "$skip_build" -eq 0 ]; then
    local build_status=0 receipt
    receipt="$(mktemp "${TMPDIR:-/tmp}/aiur-restart-receipt.XXXXXX")"
    AIUR_RESTART_BUILD_RECEIPT="$receipt" bash -c "$AIUR_RESTART_BUILD_CMD" || build_status=$?
    if [ "$build_status" -ne 0 ]; then
      # Exit with the builder's own status rather than a flat 1, so a caller can
      # still tell a failed rebuild from any other abort.
      rm -f "$receipt"
      aiur_restart_phase="rebuild_failed"
      aiur_restart_reason="rebuild_failed_exit_${build_status}"
      echo "❌ restart aborted before start: the rebuild failed" >&2
      aiur_restart_report_state
      trap - EXIT INT TERM
      exit "$build_status"
    fi

    # A builder that declares AIUR_RESTART_BUILD_VERIFIES has promised a receipt,
    # so a missing or contradicted one is a real failure and an unverifiable
    # rebuild is not a lesser success — starting anyway would hand back the
    # stale-release outcome this ordering exists to prevent, with a "restarted"
    # line on top of it. A builder that makes no such promise cannot be held to
    # it; say plainly that the guarantee did not apply rather than convert an
    # unknown wrapper into a stopped fleet.
    if [ "${AIUR_RESTART_BUILD_VERIFIES:-0}" = "1" ]; then
      local verify_status=0
      verify_restart_build "$receipt" || verify_status=$?
      rm -f "$receipt"
      if [ "$verify_status" -ne 0 ]; then
        aiur_restart_phase="rebuild_verification_failed"
        aiur_restart_reason="rebuild_verification_failed_exit_${verify_status}"
        echo "❌ restart aborted before start: the rebuild could not be verified" >&2
        # Naming the builder makes an inherited AIUR_RESTART_BUILD_CMD — a dev
        # shim leaking into another shell — diagnosable from this output alone,
        # instead of an identical refusal on every retry.
        echo "   rebuild command: ${AIUR_RESTART_BUILD_CMD}" >&2
        echo "   Rebuild from the checkout you mean and retry, or 'aiur restart --no-build'" >&2
        echo "   to start the release on disk without the guarantee." >&2
        aiur_restart_report_state
        trap - EXIT INT TERM
        exit 70
      fi
    else
      rm -f "$receipt"
      echo "aiur: UNVERIFIED rebuild — this builder reports no receipt, so restart" >&2
      echo "      cannot confirm the release it is about to boot is the one just built" >&2
    fi
  elif [ "$skip_build" -eq 1 ]; then
    echo "aiur: --no-build — restarting on the release already on disk" >&2
  fi

  # Always detached; --interactive opts into an attachable session, while a
  # foreground restart remains `aiur stop && aiur run`.
  aiur_restart_start_attempted=1
  aiur_restart_phase="startup"
  aiur_restart_reason="startup_started"
  aiur_write_restart_diagnostic
  local boot_status=0 start_status=0
  aiur_restart_start_with_retry || boot_status=$?
  restart_after_start_attempt "$boot_status" "${AIUR_LOGS_ROOT:-}/log/boot.out.log" "$previous_sha" "$snapshot_dir" "$keep_agents" || start_status=$?
  if [ "$start_status" -ne 0 ]; then
    aiur_restart_phase="startup_failed"
    aiur_restart_reason="startup_failed_exit_${start_status}"
    report_restart_handoff_failure
    trap - EXIT INT TERM
    aiur_restart_report_state
    exit "$start_status"
  fi

  aiur_restart_daemon_state="running"
  if [ "$boot_status" -ne 0 ]; then
    aiur_restart_phase="rollback_complete"
    aiur_restart_reason="new_release_failed_rolled_back"
  else
    aiur_restart_phase="complete"
    aiur_restart_reason="restart_succeeded"
  fi
  aiur_write_restart_diagnostic
}
