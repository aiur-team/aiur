defmodule Aiur.Regression.ShutdownCleanupTest do
  @moduledoc """
  Regression for "Ctrl+C leaves a stale BEAM node" (reported 2026-05-21).

  After pressing Ctrl+C in the foreground terminal, the next launch used to fail
  with a node-name-in-use or port-in-use error because the cleanup trap only
  deleted opencode session entries — it never signalled the detached aiur tmux
  session's BEAM to shut down.

  The foreground run + teardown now live in the shared engine
  (`packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `session_cleanup` +
  `install_foreground_traps`). This test checks that cleanup's source for the
  BEAM-killing + session-killing + sweep wiring; a full PTY end-to-end is manual.
  """

  use ExUnit.Case, async: true

  @engine Path.expand("../../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  describe "engine session_cleanup" do
    test "kills the aiur tmux session on EXIT/INT/TERM/HUP" do
      cleanup = cleanup_block()

      assert cleanup =~ ~r/kill-session\s+-t\s+"\$_session_name"/,
             """
             session_cleanup MUST run `tmux kill-session -t "$_session_name"` so
             SIGHUP propagates to the BEAM in the detached aiur tmux session.
             Otherwise the BEAM survives Ctrl+C, holding port 4000 + the node
             name and breaking the next launch.
             """
    end

    test "SIGTERMs then SIGKILLs only the BEAM node this run owns" do
      cleanup = cleanup_block()

      refute cleanup =~ ~r/pgrep -f "\$_session_release\/\.\*erts\.\*beam\.smp"/,
             "session_cleanup must not reap by shared release dir"

      assert cleanup =~ ~r/kill_beams_matching "-name \$\{_session_node\}"/,
             "session_cleanup MUST resolve the BEAM by this run's node name"

      assert File.read!(@engine) =~ ~r/kill -TERM/,
             "session_cleanup MUST SIGTERM the BEAM so OTP supervisors run shutdown callbacks"

      assert File.read!(@engine) =~ ~r/kill -KILL/,
             "session_cleanup MUST SIGKILL stragglers after the grace period — a wedged BEAM leaks port 4000 forever"
    end

    test "also reaps the BEAM by node name, covering a different-release-dir orphan" do
      assert cleanup_block() =~ ~r/kill_beams_matching "-name/,
             """
             session_cleanup MUST also reap by node name. Under the unified identity a
             BEAM launched from a different release dir (dev _build vs installed) holds
             the same node name, so cleanup still needs a node-name reap even after
             release-path pgrep was removed.
             """
    end

    test "sweeps orphaned agent-driver tmux sockets on close" do
      assert cleanup_block() =~ ~r/sweep_dead_tmux_sockets/,
             "session_cleanup MUST sweep so agent-driver sockets this run orphaned are reaped at close"
    end

    test "runs the workspace cwd sweep after the BEAM is dead" do
      cleanup = cleanup_block()

      assert cleanup =~ ~r/kill_beams_matching "-name \$\{_session_node\}".+reap_workspace_cwd_from_file "\$_session_workspace_root_file"/s,
             """
             session_cleanup MUST run the cwd-scoped workspace backstop after
             the BEAM node-name reap. Running it before the BEAM exits can race
             with BEAM-side cleanup and miss reparented workspace processes.
             """
    end

    test "removes the workspace root handoff tempfile" do
      assert cleanup_block() =~ ~r/rm -f .*\$_session_workspace_root_file/,
             "session_cleanup must remove the per-run workspace-root tempfile"
    end

    test "trap covers EXIT INT TERM HUP — split traps to avoid pop_var_context" do
      source = File.read!(@engine)

      assert source =~ ~r/trap 'session_cleanup' EXIT\b/,
             "EXIT trap must register session_cleanup on its own."

      for signal <- ["INT", "TERM", "HUP"] do
        assert source =~ ~r/trap '[^']*session_cleanup[^']*' #{signal}\b/,
               """
               The #{signal} trap MUST call session_cleanup (with the EXIT trap
               cleared first so cleanup runs exactly once). All four signals —
               EXIT/INT/TERM/HUP — must invoke cleanup.
               """
      end
    end

    test "foreground attach stderr filtering avoids process substitution" do
      source = File.read!(@engine)

      refute source =~ ~S|2> >(grep -v -F "[server exited]" >&2)|,
             """
             Foreground attach must not use process substitution for stderr filtering.
             The non-TTY wrapper manual-test path can reject /dev/fd/* opens, aborting
             the real CLI before the TUI appears.
             """

      assert source =~ ~r/attach -t "\$session" 2>"\$attach_stderr"/,
             "foreground attach should buffer stderr in a tempfile before filtering"
    end
  end

  describe "engine workspace cwd sweep" do
    test "is rooted in proc cwd, guarded against shallow roots, and escalates to KILL" do
      source = File.read!(@engine)

      assert source =~ "workspace_cwd_pids()",
             "engine needs a cwd-scoped pid scanner for the post-BEAM backstop"

      assert source =~ ~r/readlink "\$entry\/cwd"/,
             "workspace sweep must inspect /proc/<pid>/cwd"

      assert source =~ "workspace_root_is_shallow",
             "workspace sweep must refuse dangerously broad roots"

      assert source =~ ~r/kill -TERM "\$p"/,
             "workspace sweep must try graceful termination first"

      assert source =~ ~r/kill -KILL "\$p"/,
             "workspace sweep must force-kill survivors after the grace period"
    end

    test "cmd_stop captures the root before killing the node and sweeps after" do
      stop = cmd_stop_block()

      assert stop =~ ~r/workspace_root="\$\(current_workspace_root/,
             "cmd_stop must capture the live node's configured workspace root before killing it"

      assert stop =~ ~r/kill_beams_matching "-name \$\{AIUR_RELEASE_NODE\}".+reap_workspace_cwd_agents "\$workspace_root"/s,
             "cmd_stop must run the cwd sweep after the BEAM node-name reap"
    end

    test "watchdog receives the workspace root file and sweeps after BEAM death" do
      source = File.read!(@engine)

      assert source =~ ~s(workspace_root_file="${10:-}"),
             "watchdog must accept the workspace-root handoff file path"

      assert source =~ ~r/reap_aiur_agents "\$socket" "\$pidfile"\n\s+reap_workspace_cwd_from_file "\$workspace_root_file"/,
             "watchdog must run the cwd sweep after pidfile agent reap"

      assert source =~ ~r/start_beam_death_watchdog \\\n\s+"-name \$\{AIUR_RELEASE_NODE\}" "\$socket" "\$AIUR_AGENT_TMPFILE" 1 1 \\\n\s+"\$AIUR_RELEASE_NODE" "\$\{AIUR_LOGS_ROOT:-\}" \\\n\s+"\$\(aiur_stop_sentinel_path\)" "\$\(aiur_crash_marker_path\)" "\$AIUR_WORKSPACE_ROOT_FILE"/,
             "background watchdog must receive AIUR_WORKSPACE_ROOT_FILE"
    end
  end

  # Pull the session_cleanup body out of the engine for source asserts.
  defp cleanup_block do
    [_, block] =
      Regex.run(~r/session_cleanup\(\) \{(.+?)\n\}\ninstall_foreground_traps/us, File.read!(@engine), capture: :all)

    block
  end

  defp cmd_stop_block do
    [_, block] =
      Regex.run(~r/cmd_stop\(\) \{(.+?)\n\}\n\n# --- dispatch/us, File.read!(@engine), capture: :all)

    block
  end
end
