# Handoff restart helpers. Sourced by aiur-engine.sh.

# Evaluated on the running node, which may predate #4529 and lack the handoff
# module, so it may only use what every build has.
AIUR_HANDOFF_PREPARE_EXPRESSION='m = Aiur.Handoff.CLI
if Code.ensure_loaded?(m) and function_exported?(m, :prepare, 0) do
  m.prepare()
else
  stamp = File.read(Path.join(to_string(:code.root_dir()), "AIUR_BUILD_STAMP"))
  sha = with {:ok, text} <- stamp, [_, sha] <- Regex.run(~r/^source_sha=(\S+)/m, text), do: sha, else: (_ -> "unknown")
  IO.puts("__AIUR_CONTROL_ERROR__:running daemon #{sha} predates keep-agents (#4529); use a plain restart once, then keep-agents works")
  IO.puts("__AIUR_CONTROL_EXIT__:1")
end'

prepare_restart_handoff() {
  local output
  output="$(AIUR_CONTROL_RPC_TIMEOUT_SECONDS=120 run_control_rpc "$AIUR_HANDOFF_PREPARE_EXPRESSION")" || {
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    die "restart --keep-agents aborted before stop: handoff preflight failed"
  }
  AIUR_RESTART_HANDOFF_ID="$(printf '%s\n' "$output" | sed -n 's/^__AIUR_HANDOFF__://p')"
  [[ "$AIUR_RESTART_HANDOFF_ID" =~ ^[A-Za-z0-9_-]+$ ]] || die "handoff preflight returned no valid handoff id; nothing stopped"
}

report_restart_handoff() {
  # The daemon's report wait is bounded; leave room for its RPC envelope.
  AIUR_CONTROL_RPC_TIMEOUT_SECONDS=130 run_control_rpc \
    "Aiur.Handoff.CLI.report(expected_id: \"$AIUR_RESTART_HANDOFF_ID\", wait_ms: 120_000)" || {
    echo "aiur: daemon started; handoff outcome unavailable. Run 'aiur status --handoff --json'." >&2
  }
}

aiur_restart_start_with_retry() {
  local attempt=1 status=0 max_attempts="${AIUR_RESTART_START_ATTEMPTS:-2}"
  if ! [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]]; then max_attempts=2; fi
  while [ "$attempt" -le "$max_attempts" ]; do
    if dispatch_run --bg "${run_args[@]+"${run_args[@]}"}"; then return 0; else status=$?; fi
    [ "$attempt" -lt "$max_attempts" ] || break
    echo "aiur: restart startup attempt $attempt failed (exit $status); retrying after cleanup" >&2
    if [ -n "${release_bin:-}" ]; then
      local tmux_bin socket session conf
      tmux_bin="$(command -v tmux || true)"
      socket="${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}"
      session="${socket}-default"
      conf="$(resolve_tmux_conf)"
      [ -z "$tmux_bin" ] || "$tmux_bin" -L "$socket" -f "$conf" kill-session -t "$session" 2>/dev/null || true
      kill_beams_matching "-name ${AIUR_RELEASE_NODE}"
    fi
    sleep "${AIUR_RESTART_RETRY_DELAY_SECONDS:-1}"
    attempt=$((attempt + 1))
  done
  echo "❌ restart startup failed after $attempt attempt(s) (exit $status)" >&2
  return "$status"
}

report_restart_handoff_failure() {
  # Called only after every startup attempt failed. The report has per-session
  # fallback reasons, so make the loss visible in the command's own output too.
  [ -n "${AIUR_RESTART_HANDOFF_ID:-}" ] || return 0
  local output status=0
  output="$(AIUR_CONTROL_RPC_TIMEOUT_SECONDS=130 run_control_rpc \
    "Aiur.Handoff.CLI.report(expected_id: \"$AIUR_RESTART_HANDOFF_ID\", wait_ms: 120_000)" 2>&1)" || status=$?

  if [ "$status" -ne 0 ]; then
    echo "aiur: restart handoff $AIUR_RESTART_HANDOFF_ID outcome unavailable; sessions may be lost. Run 'aiur status --handoff --json' after recovery." >&2
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    return 0
  fi

  local fallback_count reasons
  fallback_count="$(printf '%s\n' "$output" | sed -n 's/.*fallback=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  reasons="$(printf '%s\n' "$output" | awk '$2 == "fallback" { split($3, parts, ":"); print parts[1] }' | sort -u | paste -sd, -)"
  if [ -n "$fallback_count" ] && [ "$fallback_count" -gt 0 ]; then
    echo "aiur: $fallback_count handoff session(s) lost: ${reasons:-fallback reason unavailable}" >&2
  else
    echo "aiur: handoff report did not confirm adoption; inspect 'aiur status --handoff --json'." >&2
  fi
  [ -z "$output" ] || printf '%s\n' "$output" >&2
}

write_handoff_stop() {
  local sentinel="$1" pidfile="$2"
  printf 'handoff=%s\n' "$AIUR_RESTART_HANDOFF_ID" >"$sentinel" || return 1
  # Per-launch marker also protects a foreground launcher's EXIT trap. It
  # outlives the shared stop sentinel, which the next launch clears.
  [ -z "$pidfile" ] || cp "$sentinel" "$pidfile.handoff"
}

inherit_handoff_pidfile() {
  local previous
  previous="$(agent_pidfile_from_instance_record 2>/dev/null || true)"
  if [ -n "$previous" ] && [ -s "$previous.handoff" ] && [ -f "$previous" ]; then
    cat "$previous" >>"$AIUR_AGENT_TMPFILE" || return 1
  fi
}
