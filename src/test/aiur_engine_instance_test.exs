defmodule AiurEngineInstanceTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "writes an instance record with launch identity metadata" do
    state = tmp_state()
    launch_root = Aiur.TestSupport.tmp_root!("aiur-record-root")
    File.mkdir_p!(launch_root)

    on_exit(fn ->
      File.rm_rf(state)
      File.rm_rf(launch_root)
    end)

    script = """
    cd "$LAUNCH_ROOT"
    AIUR_BG_STATE_DIR="$STATE"
    AIUR_INSTANCE_KEY=abc123
    AIUR_RELEASE_NODE=aiur-tester-abc123@127.0.0.1
    AIUR_REPO_ROOT=
    aiur_resolve_identity
    write_aiur_instance_record aiur-tester-abc123-default aiur-tester-abc123 replace headless
    cat "$(aiur_instance_record_path)"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"STATE", state},
        {"LAUNCH_ROOT", launch_root},
        # Stop config discovery at the fixture, including under workspace TMPDIR.
        {"HOME", launch_root},
        {"AIUR_RELEASE_NODE", nil},
        {"AIUR_INSTANCE_KEY", nil},
        {"AIUR_REPO_ROOT", nil}
      ])

    launch_root_real = realpath(launch_root)

    assert out =~ "AIUR_RECORD_NODE=aiur-tester-abc123@127.0.0.1"
    assert out =~ "AIUR_RECORD_INSTANCE_KEY=abc123"
    assert out =~ "AIUR_RECORD_SESSION=aiur-tester-abc123-default"
    assert out =~ "AIUR_RECORD_SOCKET=aiur-tester-abc123"
    assert out =~ "AIUR_RECORD_SURFACE_MODE=headless"
    assert out =~ "AIUR_RECORD_PROJECT_ROOT=#{launch_root_real}"
    assert out =~ "AIUR_RECORD_PROJECT_ROOT_SOURCE=cwd"
  end

  test "instance record backfill never overwrites a concurrent launch record" do
    state = tmp_state()
    on_exit(fn -> File.rm_rf(state) end)

    script = """
    AIUR_BG_STATE_DIR="$STATE"
    AIUR_INSTANCE_KEY=abc123
    AIUR_RELEASE_NODE=aiur-tester-abc123@127.0.0.1
    AIUR_PROJECT_ROOT=/original
    AIUR_PROJECT_ROOT_SOURCE=env
    AIUR_WORKSPACE_ROOT_FILE=/original/handoff
    write_aiur_instance_record aiur-tester-abc123-default aiur-tester-abc123
    AIUR_PROJECT_ROOT=/attacher
    AIUR_WORKSPACE_ROOT_FILE=
    write_aiur_instance_record aiur-tester-abc123-default aiur-tester-abc123 if-absent
    cat "$(aiur_instance_record_path)"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"STATE", state},
        {"AIUR_RELEASE_NODE", nil},
        {"AIUR_INSTANCE_KEY", nil}
      ])

    assert out =~ "AIUR_RECORD_PROJECT_ROOT=/original"
    assert out =~ "AIUR_RECORD_WORKSPACE_ROOT_FILE=/original/handoff"
    refute out =~ "/attacher"
  end

  test "global-config control RPC adopts the live launch record from a subdirectory" do
    rel = fake_release()

    File.write!(Path.join([rel, "bin", "aiur"]), """
    #!/usr/bin/env bash
    echo "NODE:$RELEASE_NODE"
    echo "__AIUR_CONTROL_EXIT__:0"
    """)

    state = tmp_state()
    base = Aiur.TestSupport.tmp_root!("aiur-control-record")
    home = Path.join(base, "home")
    launch_root = Path.join(base, "project")
    subdir = Path.join([launch_root, "nested", "dir"])
    File.mkdir_p!(home)
    File.mkdir_p!(subdir)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(base)
    end)

    live_node = "aiur-tester-live123@127.0.0.1"

    script = """
    AIUR_BG_STATE_DIR="$STATE"
    AIUR_RELEASE_NODE="$LIVE_NODE"
    AIUR_INSTANCE_KEY=live123
    AIUR_PROJECT_ROOT="$LAUNCH_ROOT"
    AIUR_PROJECT_ROOT_SOURCE=cwd
    write_aiur_instance_record aiur-tester-live123-default aiur-tester-live123

    cd "$SUBDIR"
    unset AIUR_RELEASE_NODE AIUR_INSTANCE_KEY AIUR_PROJECT_ROOT AIUR_PROJECT_ROOT_SOURCE
    AIUR_REPO_ROOT=
    probe_node_liveness() {
      case "$RELEASE_NODE" in
        "$LIVE_NODE") printf up ;;
        *) printf down ;;
      esac
    }
    run_control_rpc "Aiur.AgentControlCLI.status()"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"STATE", state},
        {"HOME", home},
        {"LAUNCH_ROOT", launch_root},
        {"SUBDIR", subdir},
        {"LIVE_NODE", live_node},
        {"AIUR_RELEASE_NODE", nil},
        {"AIUR_INSTANCE_KEY", nil},
        {"AIUR_REPO_ROOT", nil}
      ])

    assert out =~ "NODE:#{live_node}"
    refute out =~ "no running aiur node"
  end

  test "down global-config control RPC prints the stopped-daemon error" do
    state = tmp_state()
    caller = Aiur.TestSupport.tmp_root!("aiur-control-miss")
    File.mkdir_p!(caller)

    rpc = Aiur.TestSupport.tmp_root!("aiur-rpc-down")
    File.write!(rpc, "#!/usr/bin/env bash\necho transport failed >&2\nexit 42\n")
    File.chmod!(rpc, 0o755)

    on_exit(fn ->
      File.rm_rf(state)
      File.rm_rf(caller)
      File.rm(rpc)
    end)

    script = """
    cd "$CALLER"
    resolve_release() { release_bin="$RPC"; release_dir=/tmp/nonexistent-aiur-release; }
    prepare_distribution() { aiur_resolve_identity; RELEASE_NODE="$AIUR_RELEASE_NODE"; }
    probe_node_liveness() { printf down; }
    run_control_rpc "Aiur.AgentControlCLI.status()"
    """

    {out, 1} =
      run_sourced_engine(script, [
        {"AIUR_BG_STATE_DIR", state},
        {"CALLER", caller},
        {"RPC", rpc},
        {"AIUR_RELEASE_NODE", nil},
        {"AIUR_INSTANCE_KEY", nil},
        {"AIUR_REPO_ROOT", nil}
      ])

    assert out ==
             "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry.\n"
  end

  test "down control RPC with crash marker reports orphaned-agent guidance" do
    state = tmp_state()
    rpc = Aiur.TestSupport.tmp_root!("aiur-rpc-fail")

    File.write!(rpc, "#!/usr/bin/env bash\necho transport failed >&2\nexit 42\n")
    File.chmod!(rpc, 0o755)

    on_exit(fn ->
      File.rm(rpc)
      File.rm_rf(state)
    end)

    script = """
    resolve_release() { :; }
    prepare_distribution() { :; }
    probe_node_liveness() { printf down; }
    release_bin="$RPC"
    mkdir -p "$AIUR_BG_STATE_DIR"
    echo "crash details" >"$(aiur_crash_marker_path)"
    if run_control_rpc "Aiur.AgentControlCLI.status()"; then
      code=0
    else
      code=$?
    fi
    echo "CODE=$code"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_BG_STATE_DIR", state},
        {"RELEASE_NODE", "aiur-crashed@127.0.0.1"},
        {"RPC", rpc}
      ])

    assert out =~ "background daemon at aiur-crashed@127.0.0.1 is DOWN after an unexpected exit"
    assert out =~ "crash details"
    assert out =~ "run 'aiur stop' to reap any orphaned agents"
    assert out =~ "CODE=1"
    refute out =~ "start aiur and try again"
  end
end
