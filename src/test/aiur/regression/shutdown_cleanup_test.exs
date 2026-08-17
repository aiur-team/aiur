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
    test "disarms the foreground crash watchdog before stopping the daemon" do
      cleanup = cleanup_block()

      assert cleanup =~
               ~r/kill "\$_session_watchdog_pid".+kill-session\s+-t\s+"\$_session_name"/s,
             "clean foreground teardown must stop the watchdog before it stops the BEAM"
    end

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

    test "removes the per-run handoff tempfiles" do
      cleanup = cleanup_block()

      for variable <- ~w(
        _session_workspace_root_file
        _session_alert_ledger_path_file
        _session_crash_dump_baseline_file
      ) do
        assert cleanup =~ ~r/rm -f .*\$#{variable}/s,
               "session_cleanup must remove #{variable}"
      end
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

    test "cmd_stop reads the root handoff before killing the node and sweeps after" do
      stop = cmd_stop_block()

      assert stop =~ ~r/workspace_root_file="\$\(workspace_root_file_from_instance_record/,
             "cmd_stop must use the launch-time workspace root handoff before killing the node"

      assert stop =~ ~r/kill_beams_matching "-name \$\{AIUR_RELEASE_NODE\}".+reap_workspace_cwd_from_file "\$workspace_root_file"/s,
             "cmd_stop must run the cwd sweep after the BEAM node-name reap"
    end

    test "watchdog receives the workspace root file and sweeps after BEAM death" do
      source = File.read!(@engine)

      assert source =~ ~r/reap_aiur_agents "\$socket" "\$pidfile"\n\s+reap_workspace_cwd_from_file "\$workspace_root_file"/,
             "watchdog must run the cwd sweep after pidfile agent reap"
    end
  end

  describe "stale manual-smoke cleanup" do
    test "startup warns, stop reaps, and cleanup-stale is a command" do
      source = File.read!(@engine)
      stop = cmd_stop_block()

      assert source =~ "preflight_stale_manual_smoke",
             "run_session must report stale same-user manual-smoke leftovers before launching"

      assert stop =~ "reap_stale_manual_smoke",
             "aiur stop must reap stale manual-smoke BEAMs/attaches after stopping the current instance"

      assert stop =~ "reap_stale_manual_smoke 0",
             "ordinary stop must not kill wrapper tmux sessions from another active manual run"

      assert source =~ ~r/cmd_cleanup_stale\(\).+reap_stale_manual_smoke 1/s,
             "the explicit cleanup-stale command must include abandoned wrapper tmux sessions"

      assert source =~ ~r/cleanup-stale\)/,
             "the engine must expose aiur cleanup-stale for operator-initiated stale cleanup"
    end

    test "inventory reports node names and workspace roots without cookie material" do
      source = File.read!(@engine)

      assert source =~ "stale_manual_smoke_beam_inventory",
             "cleanup needs a BEAM inventory rather than one-off pgrep calls"

      assert source =~ "node=${node} workspace=${workspace_root}",
             "operator output must include node names and workspace roots"

      refute source =~ ~r/report_stale_manual_smoke.+COOKIE/s,
             "stale cleanup reports must not print cookies or token material"
    end

    test "stale BEAM cleanup is scoped to same-user issue workspaces and TERM before KILL" do
      source = File.read!(@engine)

      assert source =~ "*/aiur-workspaces/*",
             "broad stale cleanup must be scoped to issue/manual-smoke workspaces"

      assert source =~ ~r/kill -TERM "\$pid".+kill -KILL "\$pid"/s,
             "stale BEAM cleanup must try TERM before force kill"

      assert source =~ ~r/ps -p "\$1" -o user=.*\|\| true/,
             "pid owner lookup must be best-effort because processes can exit between pgrep and ps"

      assert source =~ ~r/ps -p "\$1" -o ppid=.*\|\| true/,
             "pid parent lookup must be best-effort because processes can exit between pgrep and ps"

      assert source =~ "pid_cwd()",
             "orphan opencode attach cleanup must prove workspace ownership before killing"

      assert source =~ ~r/cwd="\$\(pid_cwd "\$pid"\)"/,
             "opencode attach inventory must inspect each candidate's cwd"
    end

    test "wrapper cleanup requires a manual-test start command and post-exit sleep state" do
      source = File.read!(@engine)

      assert source =~ "*aiurdev\\ --test*",
             "wrapper cleanup must require a canonical manual smoke launch command"

      assert source =~ ~r/\[ "\$current" = "sleep" \] \|\| all_sleep=0/,
             "wrapper cleanup must only target wrappers whose panes have fallen through to sleep"

      refute source =~ ~r/\*\/aiur-workspaces\/\*\) manual_context=1/,
             "being in an issue workspace alone must not classify a wrapper as stale"
    end

    test "aborted manual-smoke BEAM is reaped by node and workspace identity" do
      log = Path.join(System.tmp_dir!(), "aiur-stale-cleanup-#{System.unique_integer([:positive])}.log")
      on_exit(fn -> File.rm(log) end)

      release_root =
        Path.join([
          System.tmp_dir!(),
          "aiur-workspaces",
          "repo",
          "552",
          "src",
          "_build",
          "dev",
          "rel",
          "aiur"
        ])

      script = stale_cleanup_script(release_root, log, "cmd_cleanup_stale")
      {_, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)

      kill_log = File.read!(log)
      assert kill_log =~ "KILL:-TERM 111"
      assert kill_log =~ "KILL:-KILL 111"
    end

    test "cleanup-stale dry-run reports without killing and rejects unknown args" do
      release_root =
        Path.join([
          System.tmp_dir!(),
          "aiur-workspaces",
          "repo",
          "553",
          "src",
          "_build",
          "dev",
          "rel",
          "aiur"
        ])

      log = Path.join(System.tmp_dir!(), "aiur-stale-dry-run-#{System.unique_integer([:positive])}.log")
      on_exit(fn -> File.rm(log) end)

      dry_run = stale_cleanup_script(release_root, log, "cmd_cleanup_stale --dry-run")
      {out, 0} = System.cmd("bash", ["-c", dry_run], stderr_to_stdout: true)
      assert out =~ "stale manual-smoke leftovers detected"
      refute File.exists?(log)

      invalid = stale_cleanup_script(release_root, log, "cmd_cleanup_stale --bogus")
      {out, 64} = System.cmd("bash", ["-c", invalid], stderr_to_stdout: true)
      assert out =~ "cleanup-stale only accepts --dry-run"
      refute File.exists?(log)
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

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp stale_cleanup_script(release_root, log, invocation) do
    """
    source #{shell_escape(@engine)}
    USER=tester
    export USER

    command() {
      if [ "${1:-}" = "-v" ] && [ "${2:-}" = "tmux" ]; then
        printf 'tmux\\n'
        return 0
      fi
      builtin command "$@"
    }

    tmux() {
      return 1
    }

    pgrep() {
      if [ "${1:-}" = "-f" ]; then
        case "${*: -1}" in
          *beam*) printf '111\\n' ;;
        esac
        return 0
      fi
      return 1
    }

    ps() {
      case "$*" in
        *"-p 111 -o user="*) printf 'tester\\n' ;;
        *"-p 111 -o command="*) printf '#{release_root}/releases/0.0.3/elixir --name aiur-tester-abc123def0@127.0.0.1 --boot-var RELEASE_LIB #{release_root}/lib\\n' ;;
        *) return 1 ;;
      esac
    }

    sleep() { return 0; }

    kill() {
      printf 'KILL:%s\\n' "$*" >> #{shell_escape(log)}
      return 0
    }

    #{invocation} 2>&1
    """
  end
end
