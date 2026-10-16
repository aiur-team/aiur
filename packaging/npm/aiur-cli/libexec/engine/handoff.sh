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
