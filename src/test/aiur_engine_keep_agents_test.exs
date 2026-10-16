defmodule AiurEngineKeepAgentsTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.EngineCase

  test "unsupported preflight leaves stop, build and start untouched" do
    {output, status} =
      run_sourced_engine(
        """
        run_control_rpc() { echo 'handoff RPC unavailable'; return 1; }
        cmd_stop() { echo STOP; }
        dispatch_run() { echo START; }
        cmd_restart --keep-agents
        """,
        [{"AIUR_RESTART_BUILD_CMD", "echo BUILD"}]
      )

    assert status != 0
    assert output =~ "handoff RPC unavailable"
    refute output =~ "STOP"
    refute output =~ "BUILD"
    refute output =~ "START"
  end

  test "restart preflights and prints the matching report" do
    {output, 0} =
      run_sourced_engine(
        """
        run_control_rpc() {
          case "$1" in
            *prepare*) echo '__AIUR_HANDOFF__:handoff-3845' ;;
            *report*) echo '3845 adopted'; echo 'gap=42ms handoff=handoff-3845' ;;
          esac
        }
        cmd_stop() { echo "STOP:$AIUR_RESTART_HANDOFF_ID"; }
        dispatch_run() { echo "START:$*"; }
        cmd_restart --keep-agents --no-build
        """,
        []
      )

    assert output =~ "STOP:handoff-3845"
    assert output =~ "START:--bg"
    refute output =~ "START:--bg --keep-agents"
    assert output =~ "3845 adopted"
    assert output =~ "gap=42ms handoff=handoff-3845"
  end

  test "watchdog consumes a handoff stop without reaping preserved providers" do
    state = tmp_state()
    File.mkdir_p!(state)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(state) end)
    sentinel = Path.join(state, "stop")
    pidfile = Path.join(state, "agents")
    File.write!(sentinel, "handoff=handoff-3845\n")
    File.write!(pidfile, "provider-record\n")

    {output, 0} =
      run_sourced_engine(
        """
        pgrep() { return 1; }
        supervisor_is_alive() { return 1; }
        reap_aiur_agents() { echo REAP >> "$STATE/events"; }
        reap_workspace_cwd_from_file() { echo SWEEP >> "$STATE/events"; }
        watchdog=$(start_beam_death_watchdog absent socket "$PIDFILE" 0.01 1 node '' "$SENTINEL")
        for i in $(seq 1 100); do
          [ ! -f "$SENTINEL" ] && break
          sleep 0.01
        done
        [ ! -f "$SENTINEL" ] && echo CONSUMED
        [ ! -f "$STATE/events" ] && echo PRESERVED
        """,
        [{"STATE", state}, {"PIDFILE", pidfile}, {"SENTINEL", sentinel}]
      )

    assert output =~ "CONSUMED"
    assert output =~ "PRESERVED"
    assert File.read!(pidfile) == "provider-record\n"
  end

  test "failed rebuild reports retained providers and never starts" do
    {output, status} =
      run_sourced_engine(
        """
        run_control_rpc() { echo '__AIUR_HANDOFF__:retained'; }
        cmd_stop() { echo STOP; }
        dispatch_run() { echo START; }
        cmd_restart --keep-agents
        """,
        [{"AIUR_RESTART_BUILD_CMD", "exit 42"}]
      )

    assert status == 42
    assert output =~ "handoff retained and providers retained"
    assert output =~ "orphan timeout"
    refute output =~ "START"
  end

  test "the next launch inherits the preserved pidfile without its cleanup marker" do
    state = tmp_state()
    File.mkdir_p!(state)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(state) end)
    old = Path.join(state, "old-agents")
    next = Path.join(state, "next-agents")
    File.write!(old, "provider-record\n")
    File.write!(old <> ".handoff", "handoff=retained\n")
    File.write!(next, "")

    {_output, 0} =
      run_sourced_engine(
        """
        agent_pidfile_from_instance_record() { printf '%s' "$OLD"; }
        AIUR_AGENT_TMPFILE="$NEXT"
        inherit_handoff_pidfile
        """,
        [{"OLD", old}, {"NEXT", next}]
      )

    assert File.read!(next) == "provider-record\n"
    refute File.exists?(next <> ".handoff")
  end

  test "handoff stop kills only the daemon socket and preserves the record and pidfile" do
    state = tmp_state()
    File.mkdir_p!(Path.join(state, "bin"))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(state) end)
    File.write!(Path.join(state, "bin/tmux"), "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$STATE/tmux.log\"\n")
    File.chmod!(Path.join(state, "bin/tmux"), 0o755)
    File.write!(Path.join(state, "agents"), "live-provider\n")
    File.write!(Path.join(state, "instance"), "instance-record\n")

    {output, 0} =
      run_sourced_engine(
        """
        resolve_release() { :; }
        aiur_resolve_identity() { :; }
        resolve_control_identity_from_records() { AIUR_CONTROL_ADOPTED_RECORD=1; }
        workspace_root_file_from_instance_record() { echo "$STATE/root"; }
        agent_pidfile_from_instance_record() { echo "$STATE/agents"; }
        load_aiur_instance_record() { AIUR_RECORD_AGENT_SOCKET=preserved-agents; }
        aiur_instance_record_path() { echo "$STATE/instance"; }
        aiur_stop_sentinel_path() { echo "$STATE/stop"; }
        aiur_crash_marker_path() { echo "$STATE/crash"; }
        kill_beams_matching() { echo BEAM_STOP; }
        reap_workspace_cwd_from_file() { echo WRONG_SWEEP; }
        reap_aiur_agents() { echo WRONG_REAP; }
        AIUR_SESSION_PREFIX=keep-agents-unit
        AIUR_RESTART_HANDOFF_ID=keep-test
        cmd_stop
        """,
        [{"STATE", state}, {"AIUR_BG_STATE_DIR", state}, {"PATH", Path.join(state, "bin") <> ":" <> System.get_env("PATH")}]
      )

    assert output =~ "BEAM_STOP"
    refute output =~ "WRONG"
    events = File.read!(Path.join(state, "tmux.log"))
    assert events =~ "kill-server"
    refute events =~ "preserved-agents kill-server"
    assert File.read!(Path.join(state, "agents")) == "live-provider\n"
    assert File.read!(Path.join(state, "instance")) == "instance-record\n"
    assert File.read!(Path.join(state, "stop")) == "handoff=keep-test\n"
    assert File.read!(Path.join(state, "agents.handoff")) == "handoff=keep-test\n"
  end

  test "failed successor startup reports unknown survival rather than promised retention" do
    {output, status} =
      run_sourced_engine(
        """
        run_control_rpc() { echo '__AIUR_HANDOFF__:attempted'; }
        cmd_stop() { echo STOP; }
        dispatch_run() { return 23; }
        cmd_restart --keep-agents --no-build
        """,
        []
      )

    assert status == 23
    assert output =~ "handoff attempted; startup was attempted, so provider survival is unknown"
    refute output =~ "providers retained until"
  end
end
