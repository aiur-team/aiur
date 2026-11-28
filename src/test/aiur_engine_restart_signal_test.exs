defmodule AiurEngineRestartSignalTest do
  @moduledoc """
  `restart` must leave a running daemon behind or exit non-zero saying why.

  The reported failure: a caller ran `timeout 300 aiur restart --keep-agents`.
  The stop was slow, so the timeout's SIGTERM reached the restart's whole
  process group while the successor was booting. The start subshell died, the
  restart resumed after its trap and counted that as a failed boot, its retry
  cleanup SIGTERMed the healthy successor, and the retry then waited on the
  launch lock its own pid still owned. The daemon stayed down.
  """
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  setup do
    tmp = Aiur.TestSupport.tmp_root!("restart-signal")
    File.mkdir_p!(tmp)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(tmp) end)
    %{tmp: tmp, events: Path.join(tmp, "events")}
  end

  # Runs the sourced engine as the leader of a new process group, so a
  # `kill -TERM 0` inside it reaches exactly the restart's processes, as
  # `timeout` does, and never the test runner.
  defp run_in_own_group(script, env) do
    node = "aiur-enginetest-#{System.unique_integer([:positive])}@127.0.0.1"

    System.cmd("setsid", ["--wait", "bash", "-c", "set -euo pipefail\nsource \"$AIUR_ENGINE\"\n#{script}"],
      env: [{"AIUR_ENGINE", engine()}, {"AIUR_RELEASE_NODE", node} | env],
      stderr_to_stdout: true
    )
  end

  defp events(path), do: path |> File.read!() |> String.split("\n", trim: true)

  test "a SIGTERM to the restart's process group while the successor boots finishes the start", %{tmp: tmp, events: events} do
    {out, status} =
      run_in_own_group(
        """
        run_control_rpc() {
          case "$1" in
            *prepare*) echo '__AIUR_HANDOFF__:handoff-timeout' ;;
            *report*) echo 'HANDOFF handoff-timeout adopted=3 fallback=0' ;;
          esac
        }
        restart_daemon_confirmed_down() { return 1; }
        cmd_stop() { echo STOP >>"$EVENTS"; }
        dispatch_run() {
          echo "START:$*" >>"$EVENTS"
          kill -TERM 0
          for _ in 1 2 3 4 5; do sleep 0.05; done
          echo READY >>"$EVENTS"
        }
        cmd_restart --keep-agents --no-build
        """,
        [{"EVENTS", events}, {"TMPDIR", tmp}, {"AIUR_RESTART_RETRY_DELAY_SECONDS", "0"}]
      )

    assert events(events) == ["STOP", "START:--bg", "READY"]
    assert status == 143
    assert out =~ "restart received SIGTERM after the stop"
    assert out =~ "the daemon is running"
    assert out =~ "adopted=3"
    refute out =~ "NOT restarted"
  end

  test "a SIGTERM before the stop aborts the restart without stopping anything", %{tmp: tmp, events: events} do
    {out, status} =
      run_in_own_group(
        """
        run_control_rpc() { kill -TERM 0; echo '__AIUR_HANDOFF__:handoff-early'; }
        restart_daemon_confirmed_down() { return 1; }
        cmd_stop() { echo STOP >>"$EVENTS"; }
        dispatch_run() { echo START >>"$EVENTS"; }
        cmd_restart --keep-agents --no-build
        """,
        [{"EVENTS", events}, {"TMPDIR", tmp}]
      )

    assert status == 143
    refute File.exists?(events)
    refute out =~ "STOPPED"
  end

  test "a retry is not blocked by the launch lock the failed attempt left behind", %{tmp: tmp, events: events} do
    {out, status} =
      run_sourced_engine(
        """
        cmd_stop() { :; }
        dispatch_run() {
          echo START >>"$EVENTS"
          if [ ! -f "$TMPDIR/attempted" ]; then
            : >"$TMPDIR/attempted"
            acquire_aiur_launch_lock "$(aiur_launch_lock_path)"
            exit 1
          fi
          acquire_aiur_launch_lock "$(aiur_launch_lock_path)" || exit 75
          echo READY >>"$EVENTS"
        }
        cmd_restart --no-build
        """,
        [
          {"EVENTS", events},
          {"TMPDIR", tmp},
          {"AIUR_BG_STATE_DIR", Path.join(tmp, "state")},
          {"AIUR_LAUNCH_LOCK_TICKS", "5"},
          {"AIUR_RESTART_RETRY_DELAY_SECONDS", "0"}
        ]
      )

    assert status == 0, out
    assert events(events) == ["START", "START", "READY"]
    refute out =~ "another launch for this directory is still in progress"
  end

  test "restart --keep-agents starts the daemon when nothing is running", %{tmp: tmp, events: events} do
    {out, status} =
      run_sourced_engine(
        """
        resolve_release() { :; }
        prepare_distribution() { :; }
        resolve_control_identity_from_records() { :; }
        release_bin=/test/release/bin/aiur
        probe_node_liveness() { printf down; }
        run_control_rpc() { echo "RPC:$1" >>"$EVENTS"; return 1; }
        cmd_stop() { echo STOP >>"$EVENTS"; AIUR_STOP_FOUND_NOTHING=1; return 1; }
        dispatch_run() { echo "START:$*:${AIUR_RESTART_HANDOFF_ID:-none}" >>"$EVENTS"; }
        cmd_restart --keep-agents --no-build
        """,
        [{"EVENTS", events}, {"TMPDIR", tmp}]
      )

    assert status == 0, out
    assert events(events) == ["STOP", "START:--bg:none"]
    assert out =~ "nothing is running, so there are no agents to keep"
    refute out =~ "aborted before stop"
  end

  test "restart --keep-agents still refuses when the daemon is up but the preflight fails", %{tmp: tmp, events: events} do
    {out, status} =
      run_sourced_engine(
        """
        resolve_release() { :; }
        prepare_distribution() { :; }
        resolve_control_identity_from_records() { :; }
        probe_node_liveness() { printf up; }
        run_control_rpc() { echo 'handoff RPC unavailable'; return 1; }
        cmd_stop() { echo STOP >>"$EVENTS"; }
        dispatch_run() { echo START >>"$EVENTS"; }
        cmd_restart --keep-agents --no-build
        """,
        [{"EVENTS", events}, {"TMPDIR", tmp}]
      )

    assert status != 0
    assert out =~ "restart --keep-agents aborted before stop: handoff preflight failed"
    refute File.exists?(events)
  end
end
