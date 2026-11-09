defmodule AiurEngineHandoffReportTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "restart continues when the release has no epmd executable" do
    release = Aiur.TestSupport.tmp_root!("restart-no-epmd-binary")
    File.mkdir_p!(release)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(release) end)

    {out, 0} =
      run_sourced_engine(
        "release_dir=#{inspect(release)}; probe_node_liveness() { printf unknown; }; wait_for_node_name_release 'aiur-test@127.0.0.1' && echo RELEASED",
        []
      )

    assert out =~ "release has no epmd binary"
    assert out =~ "RELEASED"
  end

  test "successful restart reports lost handoff sessions" do
    {out, 0} =
      run_sourced_engine(
        """
        run_control_rpc() {
          case "$1" in
            *prepare*) echo '__AIUR_HANDOFF__:handoff-success' ;;
            *report*) echo 'HANDOFF handoff-success adopted=0 fallback=3 gap=104064ms'; echo 'ticket-1 fallback relay_gone' ;;
          esac
        }
        cmd_stop() { :; }
        dispatch_run() { echo RUN; }
        cmd_restart --keep-agents --no-build
        """,
        []
      )

    assert out =~ "3 handoff session(s) lost: relay_gone"
    assert out =~ "adopted=0 fallback=3 gap=104064ms"
  end

  test "handoff status reads the durable restart phase after a successful restart" do
    state_dir = Aiur.TestSupport.tmp_root!("restart-diagnostic")
    File.mkdir_p!(state_dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(state_dir) end)

    {out, 0} =
      run_sourced_engine(
        """
        run_control_rpc() {
          case "$1" in
            *prepare*) echo '__AIUR_HANDOFF__:handoff-diagnostic' ;;
            *report*) echo 'HANDOFF handoff-diagnostic adopted=1 fallback=0 gap=10ms' ;;
          esac
        }
        cmd_stop() { :; }
        dispatch_run() { :; }
        cmd_restart --keep-agents --no-build
        cmd_status --handoff
        """,
        [{"AIUR_BG_STATE_DIR", state_dir}]
      )

    assert out =~ "LAST KEEP-AGENTS RESTART (durable launcher evidence)"
    assert out =~ "handoff_id=handoff-diagnostic"
    assert out =~ "phase=complete"
    assert out =~ "reason=restart_succeeded"
  end

  test "handoff status preserves unexpected-exit evidence cleared by restart stop" do
    state_dir = Aiur.TestSupport.tmp_root!("restart-crash-evidence")
    File.mkdir_p!(state_dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(state_dir) end)

    {out, 0} =
      run_sourced_engine(
        """
        aiur_resolve_identity
        mkdir -p "$AIUR_BG_STATE_DIR"
        printf 'unexpected daemon exit\\ncrash_dump_slogan: nodistribution\\n' >"$(aiur_crash_marker_path)"
        resolve_release() { release_bin=""; }
        resolve_control_identity_from_records() { AIUR_CONTROL_ADOPTED_RECORD=1; AIUR_CONTROL_CURRENT_NODE_STATE=down; }
        kill_beams_matching() { :; }
        run_control_rpc() {
          case "$1" in
            *prepare*) echo '__AIUR_HANDOFF__:handoff-crash' ;;
            *report*) echo 'HANDOFF handoff-crash adopted=0 fallback=1 gap=500ms' ;;
          esac
        }
        dispatch_run() { :; }
        cmd_restart --keep-agents --no-build
        test ! -e "$(aiur_crash_marker_path)"
        cmd_status --handoff
        """,
        [{"AIUR_BG_STATE_DIR", state_dir}]
      )

    assert out =~ "PREVIOUS DAEMON EXIT EVIDENCE"
    assert out =~ "crash_dump_slogan: nodistribution"
  end
end
