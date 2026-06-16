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

    test "SIGTERMs then SIGKILLs the release BEAM this run owns" do
      cleanup = cleanup_block()

      assert cleanup =~ ~r/pgrep -f "\$_session_release\/\.\*erts\.\*beam\.smp"/,
             "session_cleanup MUST resolve the BEAM by this run's release dir"

      assert cleanup =~ ~r/kill -TERM/,
             "session_cleanup MUST SIGTERM the BEAM so OTP supervisors run shutdown callbacks"

      assert cleanup =~ ~r/kill -KILL/,
             "session_cleanup MUST SIGKILL stragglers after the grace period — a wedged BEAM leaks port 4000 forever"
    end

    test "also reaps the BEAM by node name, covering a different-release-dir orphan" do
      assert cleanup_block() =~ ~r/kill_beams_matching "-name/,
             """
             session_cleanup MUST also reap by node name. Under the unified identity a
             BEAM launched from a different release dir (dev _build vs installed) holds
             the same node name, so a release-path pgrep alone leaves it stranded and the
             next launch fails with "name seems to be in use".
             """
    end

    test "sweeps orphaned agent-driver tmux sockets on close" do
      assert cleanup_block() =~ ~r/sweep_dead_tmux_sockets/,
             "session_cleanup MUST sweep so agent-driver sockets this run orphaned are reaped at close"
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
  end

  # Pull the session_cleanup body out of the engine for source asserts.
  defp cleanup_block do
    [_, block] =
      Regex.run(~r/session_cleanup\(\) \{(.+?)\n\}\ninstall_foreground_traps/us, File.read!(@engine), capture: :all)

    block
  end
end
