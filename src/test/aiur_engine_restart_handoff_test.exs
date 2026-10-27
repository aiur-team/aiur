defmodule AiurEngineRestartHandoffTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "restart retries a failed distribution boot and succeeds on the next launch" do
    tmp = Aiur.TestSupport.tmp_root!("restart-boot-retry")
    File.mkdir_p!(tmp)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(tmp) end)

    {out, 0} =
      run_sourced_engine(
        """
        attempts="$TMPDIR/restart-attempts"
        dispatch_run() {
          count=0
          [ ! -f "$attempts" ] || count="$(cat "$attempts")"
          count=$((count + 1)); printf '%s' "$count" > "$attempts"
          if [ "$count" -eq 1 ]; then echo 'nodistribution'; exit 1; fi
          echo "RUN:$*"
        }
        cmd_stop() { echo STOP; }
        cmd_restart --no-build
        """,
        [{"TMPDIR", tmp}, {"AIUR_RESTART_RETRY_DELAY_SECONDS", "0"}]
      )

    assert out =~ "restart startup attempt 1 failed (exit 1); retrying after cleanup"
    assert out =~ "RUN:--bg"
  end

  test "restart treats an absent local epmd daemon as a released node name" do
    release = Aiur.TestSupport.tmp_root!("restart-no-epmd")
    epmd_dir = Path.join(release, "erts-1/bin")
    File.mkdir_p!(epmd_dir)
    epmd = Path.join(epmd_dir, "epmd")
    File.write!(epmd, "#!/bin/sh\nexit 1\n")
    File.chmod!(epmd, 0o755)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(release) end)

    {out, 0} =
      run_sourced_engine(
        "sleep() { echo SLEPT; }; release_dir=#{inspect(release)}; probe_node_liveness() { printf unknown; }; wait_for_node_name_release 'aiur-test@127.0.0.1' && echo RELEASED",
        []
      )

    assert out =~ "RELEASED"
    refute out =~ "SLEPT"
  end

  test "restart returns the failed boot status and reports lost handoff sessions" do
    {out, status} =
      run_sourced_engine(
        """
        run_control_rpc() {
          case "$1" in
            *prepare*) echo '__AIUR_HANDOFF__:handoff-failed' ;;
            *report*) echo 'HANDOFF handoff-failed adopted=0 fallback=12 gap=104064ms'; echo 'ticket-1 fallback relay_gone' ;;
          esac
        }
        cmd_stop() { :; }
        dispatch_run() { echo nodistribution; return 23; }
        cmd_restart --keep-agents --no-build
        """,
        [{"AIUR_RESTART_START_ATTEMPTS", "1"}]
      )

    assert status == 23
    assert out =~ "restart startup failed after 1 attempt(s) (exit 23)"
    assert out =~ "12 handoff session(s) lost: relay_gone"
    assert out =~ "adopted=0 fallback=12 gap=104064ms"
    assert out =~ "ticket-1 fallback relay_gone"
    assert out =~ "STOPPED and was NOT restarted"
  end

  test "restart names ticket fallbacks reported during handoff preflight" do
    {out, 0} =
      run_sourced_engine(
        """
        run_control_rpc() {
          case "$1" in
            *prepare*)
              printf '%s\\n' '__AIUR_HANDOFF__:handoff-1' 'Handoff ticket fallback: ISSUE-42 (snapshot_timeout)'
              ;;
            *report*) echo 'HANDOFF handoff-1 adopted=0 fallback=1 gap=100ms'; echo 'ISSUE-42 fallback snapshot_timeout' ;;
          esac
        }
        cmd_stop() { :; }
        dispatch_run() { echo "RUN:$*"; }
        cmd_restart --keep-agents --no-build
        """,
        []
      )

    assert out =~ "Handoff ticket fallback: ISSUE-42 (snapshot_timeout)"
    assert out =~ "ISSUE-42 fallback snapshot_timeout"
    refute out =~ "__AIUR_HANDOFF__:"
  end
end
