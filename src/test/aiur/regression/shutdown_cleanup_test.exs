defmodule Aiur.Regression.ShutdownCleanupTest do
  @moduledoc """
  Regression for "Ctrl+C leaves a stale BEAM node" (reported 2026-05-21).

  After pressing Ctrl+C in the foreground `aiurdev` terminal, the next
  `aiurdev` invocation used to fail with one of:

      Protocol 'inet_tcp': the name aiurdev-orangekid@127.0.0.1 seems to be
      in use by another Erlang node

      aiurdev: port 4000 in use; bound to 4001 instead

  Root cause: `scripts/aiurdev`'s `__aiur_cleanup` trap only deleted opencode
  session DB entries — it didn't signal the detached aiur tmux session's
  BEAM to shut down.

  This test checks the cleanup function's source for the BEAM-killing
  wiring. A full end-to-end test (drive aiur in a PTY, send SIGINT,
  wait for BEAM exit) lives at `test/regression/aiur-shutdown.sh` —
  manual to run because real BEAM startup takes ~8 s and ExUnit live
  tests are flaky in CI.
  """

  use ExUnit.Case, async: true

  @scripts_aiur Path.expand("../../../../scripts/aiurdev", __DIR__)

  describe "scripts/aiurdev __aiur_cleanup" do
    test "kills the aiur tmux session on EXIT/INT/TERM/HUP" do
      source = File.read!(@scripts_aiur)

      cleanup_block = extract_cleanup_block(source)

      assert cleanup_block =~ ~r/kill-session\s+-t\s+"\$session"/,
             """
             __aiur_cleanup MUST run `tmux kill-session -t "$session"` so
             SIGHUP propagates to the BEAM running inside the detached
             aiur tmux session. Without this, the BEAM survives Ctrl+C
             and holds port 4000 + the registered Erlang node name,
             breaking the next `aiur` invocation.
             """
    end

    test "SIGTERMs the release BEAM owned by this wrapper" do
      source = File.read!(@scripts_aiur)
      cleanup_block = extract_cleanup_block(source)

      assert cleanup_block =~ ~r/_aiur_beam_under_pid "\$__aiur_owned_pane_pid" "\$trap_elixir_dir"/,
             "__aiur_cleanup MUST resolve the BEAM owned by this wrapper's tmux pane"

      assert cleanup_block =~ ~r/kill -TERM/,
             "__aiur_cleanup MUST send SIGTERM to the owned BEAM so OTP supervisors run shutdown callbacks"

      assert cleanup_block =~ ~r/kill -KILL/,
             "__aiur_cleanup MUST SIGKILL stragglers after the SIGTERM grace period — otherwise a wedged BEAM leaks port 4000 forever"
    end

    test "sweeps orphaned agent-driver tmux sockets on close" do
      source = File.read!(@scripts_aiur)
      cleanup_block = extract_cleanup_block(source)

      assert cleanup_block =~ ~r/sweep_dead_tmux_sockets/,
             """
             __aiur_cleanup MUST call sweep_dead_tmux_sockets so the agent-driver
             sockets this run orphaned are reaped at close, not deferred to the
             next invocation's pre-launch sweep.
             """
    end

    test "sweeps stale aiur temp artifacts on close" do
      source = File.read!(@scripts_aiur)
      cleanup_block = extract_cleanup_block(source)

      assert cleanup_block =~ ~r/sweep_stale_aiur_tmp_artifacts/,
             """
             __aiur_cleanup MUST call sweep_stale_aiur_tmp_artifacts so stale
             /tmp/aiur-* files and dirs from previous runs are reaped during
             normal foreground-session cleanup.
             """
    end

    test "trap covers EXIT INT TERM HUP — split traps to avoid pop_var_context" do
      source = File.read!(@scripts_aiur)

      # EXIT keeps its own bare-handler trap; signal traps clear the
      # other traps first and call cleanup directly, so the EXIT
      # handler doesn't fire a second time after the signal-triggered
      # exit. Without that split, Ctrl+C reproduces the bash error
      # `pop_var_context: head of shell_variables not a function context`.
      assert source =~ ~r/trap '[^']*__aiur_cleanup[^']*' EXIT\b/,
             "EXIT trap must register __aiur_cleanup on its own."

      for signal <- ["INT", "TERM", "HUP"] do
        assert source =~ ~r/trap '[^']*__aiur_cleanup[^']*' #{signal}\b/,
               """
               The #{signal} trap MUST call __aiur_cleanup (with the EXIT
               trap cleared first so cleanup runs exactly once). All four
               signals — EXIT/INT/TERM/HUP — must invoke cleanup so we
               cover terminal close, kill -9, SIGHUP-on-parent-exit, etc.
               """
      end
    end
  end

  # Pull the __aiur_cleanup function body out of scripts/aiurdev for source
  # asserts. Stops at the next top-level function or trap line.
  defp extract_cleanup_block(source) do
    # Match the function body, then any trailing comment block (the
    # signal-isolation explanatory comments live between `}` and the
    # `trap` line). `[^\n]*` instead of `.*` so non-ASCII characters
    # in comments (em-dashes, smart quotes) don't confuse the matcher.
    [_, block] =
      Regex.run(
        ~r/__aiur_cleanup\(\) \{(.+?)\n  \}\n(?:\n  #[^\n]*)*\n  trap /us,
        source,
        capture: :all
      )

    block
  end
end
