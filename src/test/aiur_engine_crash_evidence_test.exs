defmodule AiurEngineCrashEvidenceTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "engine raises the daemon core limit to the inherited hard limit" do
    {out, 0} =
      run_sourced_engine(
        ~S|ulimit -Sc 0; ulimit -Hc 2048; aiur_enable_core_dumps; test "$(ulimit -Sc)" = 2048 && echo CORE_LIMIT_MATCH|,
        []
      )

    assert out =~ "CORE_LIMIT_MATCH"
  end

  test "engine refuses a crash dump path it cannot write" do
    tmp = Aiur.TestSupport.tmp_root!("aiur-crash-dump-unwritable")
    File.mkdir_p!(tmp)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(tmp) end)

    {out, 1} =
      run_sourced_engine(
        ~S|mktemp() { return 1; }; aiur_prepare_dump_target "$ROOT/logs" "$ROOT/dumps/erl_crash.dump"|,
        [{"ROOT", tmp}, {"TMPDIR", tmp}]
      )

    assert out =~ "BEAM crash dump path is not writable"
  end

  test "engine accepts an existing writable dump file and rejects a directory" do
    tmp = Aiur.TestSupport.tmp_root!("aiur-crash-dump-existing")
    dump = Path.join(tmp, "erl_crash.dump")
    File.mkdir_p!(tmp)
    File.write!(dump, "previous dump")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(tmp) end)

    {accepted, 0} =
      run_sourced_engine(
        ~S|aiur_prepare_dump_target "$ROOT/logs" "$ROOT/erl_crash.dump"; test -f "$ROOT/erl_crash.dump" && echo EXISTING_DUMP_ACCEPTED|,
        [{"ROOT", tmp}, {"TMPDIR", tmp}]
      )

    assert accepted =~ "EXISTING_DUMP_ACCEPTED"

    {rejected, 1} =
      run_sourced_engine(
        ~S|mkdir -p "$ROOT/logs/log/directory"; aiur_prepare_dump_target "$ROOT/logs" "$ROOT/logs/log/directory"|,
        [{"ROOT", tmp}, {"TMPDIR", tmp}]
      )

    assert rejected =~ "BEAM crash dump path is not a writable file"
  end

  test "fresh foreground pane receives its launcher pid and tmux bridge helper" do
    rel = fake_release()
    state = tmp_state()
    tmp = Aiur.TestSupport.tmp_root!("aiur-launcher-watchdog")
    pane_copy = Path.join(tmp, "pane.sh")
    session = Path.join(tmp, "session")
    helper_option = Path.join(tmp, "ctrlc-option")
    File.mkdir_p!(tmp)

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*)
          cp "#{tmp}"/aiur-pane.* "#{pane_copy}"
          touch "#{session}"
          exit 0
          ;;
        *" has-session "*) [ -f "#{session}" ]; exit $? ;;
        *" set-option -g @aiur_ctrlc "*) echo "$*" > "#{helper_option}"; exit 0 ;;
        *" attach "*) exit 0 ;;
        *" kill-session "*) rm -f "#{session}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(rel)
      Aiur.TestCleanup.rm_rf!(state)
      Aiur.TestCleanup.rm_rf!(tmp)
    end)

    script = """
    export TMPDIR="$TMP_ROOT"
    probe_control_liveness() { printf up; }
    start_beam_death_watchdog() { printf '424242\\n'; }
    reap_aiur_agents() { :; }
    kill_beams_matching() { :; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    echo "LAUNCHER_PID=$$"
    run_session foreground --no-dashboard
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"TMP_ROOT", tmp},
        {"XDG_RUNTIME_DIR", tmp},
        {"AIUR_LOGS_ROOT", Path.join(tmp, "logs")},
        {"PATH", "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"},
        {"AIUR_LAUNCHER_PID", "999999"}
      ])

    [_, launcher_pid] = Regex.run(~r/LAUNCHER_PID=(\d+)/, out)
    assert File.read!(pane_copy) =~ "export AIUR_LAUNCHER_PID=#{launcher_pid}\n"
    assert File.read!(pane_copy) =~ "aiur_enable_core_dumps\n"
    refute File.read!(pane_copy) =~ "export AIUR_LAUNCHER_PID=999999\n"
    assert File.read!(helper_option) =~ "set-option -g @aiur_ctrlc #{Path.dirname(engine())}/aiur-pane-ctrlc"
    assert File.dir?(Path.join(tmp, "logs/log"))
    refute File.exists?(Path.join(tmp, "logs/erl_crash.dump"))
  end
end
