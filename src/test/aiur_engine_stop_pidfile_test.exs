defmodule AiurEngineStopPidfileTest do
  use ExUnit.Case, async: true

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  test "stop reaps only its recorded pidfile for live and crashed instances" do
    root = Aiur.TestSupport.tmp_root!("aiur-stop-pidfile")
    state = Path.join(root, "state")
    runtime = Path.join(root, "runtime")
    target = Path.join(runtime, "aiur-101-agents")
    sibling = Path.join(runtime, "aiur-202-agents")
    events = Path.join(root, "events")
    fake_bin = Path.join(root, "bin")

    File.mkdir_p!(state)
    File.mkdir_p!(runtime)
    File.mkdir_p!(fake_bin)
    File.write!(target, "pid 101 codex\n")
    File.write!(sibling, "pid 202 codex\n")
    File.write!(events, "")
    File.write!(Path.join(fake_bin, "tmux"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(fake_bin, "tmux"), 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    script = ~S"""
    source "$AIUR_ENGINE"
    resolve_release() { :; }
    aiur_resolve_identity() { :; }
    probe_node_liveness() { printf up; }
    kill_beams_matching() { :; }
    reap_workspace_cwd_from_file() { :; }
    reap_aiur_agents() { printf 'REAP:%s\n' "$2" >> "$EVENTS"; }
    reap_stale_manual_smoke() { :; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    warn_other_aiur_daemons() { :; }

    AIUR_PROJECT_ROOT="$ROOT"
    AIUR_PROJECT_ROOT_SOURCE=env
    AIUR_AGENT_TMPFILE="$TARGET"
    write_aiur_instance_record aiur-test-default aiur-test
    unset AIUR_AGENT_TMPFILE
    cmd_stop

    # A crash marker allows the same instance's recorded orphan file to be
    # cleaned even after its node has gone down.
    printf 'pid 101 codex\n' > "$TARGET"
    AIUR_AGENT_TMPFILE="$TARGET"
    write_aiur_instance_record aiur-test-default aiur-test
    unset AIUR_AGENT_TMPFILE
    AIUR_PROJECT_ROOT_SOURCE=cwd
    : > "$(aiur_crash_marker_path)"
    probe_node_liveness() { printf down; }
    cmd_stop
    cat "$EVENTS"
    """

    {output, 0} =
      System.cmd("bash", ["-c", "set -euo pipefail\n" <> script],
        env: [
          {"AIUR_ENGINE", @engine},
          {"AIUR_BG_STATE_DIR", state},
          {"AIUR_RELEASE_NODE", "aiur-stop-pidfile-test@127.0.0.1"},
          {"AIUR_INSTANCE_KEY", "test"},
          {"AIUR_SESSION_PREFIX", "aiur"},
          {"XDG_RUNTIME_DIR", runtime},
          {"ROOT", root},
          {"TARGET", target},
          {"EVENTS", events},
          {"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}
        ],
        stderr_to_stdout: true
      )

    assert length(String.split(output, "REAP:#{target}\n")) == 3
    refute output =~ "REAP:#{sibling}\n"
    refute File.exists?(target)
    assert File.read!(sibling) == "pid 202 codex\n"
  end
end
