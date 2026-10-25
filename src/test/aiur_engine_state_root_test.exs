defmodule AiurEngineStateRootTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "background run logs follow AIUR_STATE_DIR" do
    state_root = Aiur.TestSupport.tmp_root!("aiur-engine-state")
    tmp = Aiur.TestSupport.tmp_root!("aiur-engine-log-root")

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(state_root)
      Aiur.TestCleanup.rm_rf!(tmp)
    end)

    script = """
    mode=background
    session=test-session
    socket=test-socket
    conf=/fake/tmux.conf
    release_dir=/fake/release
    engine_source="$AIUR_ENGINE"
    load_dotenv() { :; }
    scrub_run_only_env() { :; }
    cli_package_version() { printf '1.0.0'; }
    init_argv_file() { argv_file="$TMP_ROOT/argv"; }
    build_run_argv() { run_argv=(); }
    write_argv() { :; }
    build_release_cmd() { :; }
    preflight_stale_manual_smoke() { :; }
    inherit_handoff_pidfile() { :; }
    run_session_prepare_env
    printf 'LOGS_ROOT=%s\\n' "$AIUR_LOGS_ROOT"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_STATE_DIR", state_root},
        {"AIUR_BG_STATE_DIR", Path.join(tmp, "engine-state")},
        {"HOME", Path.join(tmp, "home")},
        {"TMPDIR", tmp},
        {"XDG_RUNTIME_DIR", tmp},
        {"TMP_ROOT", tmp}
      ])

    assert out =~ "LOGS_ROOT=#{state_root}/logs/"
  end
end
