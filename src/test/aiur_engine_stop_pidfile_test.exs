defmodule AiurEngineStopPidfileTest do
  use ExUnit.Case, async: true

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  test "stop reaps only its own pidfile for live, crashed, and legacy instances" do
    root = Aiur.TestSupport.tmp_root!("aiur-stop-pidfile")
    state = Path.join(root, "state")
    runtime = Path.join(root, "runtime")
    target = Path.join(runtime, "aiur-101-agents")
    sibling = Path.join(runtime, "aiur-202-agents")
    handoff = Path.join(runtime, "aiur-101-workspace-root")
    events = Path.join(root, "events")
    fake_bin = Path.join(root, "bin")

    File.mkdir_p!(state)
    File.mkdir_p!(runtime)
    File.mkdir_p!(fake_bin)
    File.write!(target, "pid 101 codex\n")
    File.write!(sibling, "pid 202 codex\n")
    File.write!(handoff, root <> "\n")
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

    # An older instance record has the launcher's workspace handoff but no
    # agent pidfile field. Its matching pidfile is still attributable.
    printf 'pid 101 codex\n' > "$TARGET"
    AIUR_AGENT_TMPFILE="$TARGET"
    AIUR_WORKSPACE_ROOT_FILE="$HANDOFF"
    write_aiur_instance_record aiur-test-default aiur-test
    grep -v '^AIUR_RECORD_AGENT_TMPFILE=' "$(aiur_instance_record_path)" > "$STATE/legacy-record"
    mv "$STATE/legacy-record" "$(aiur_instance_record_path)"
    unset AIUR_AGENT_TMPFILE AIUR_WORKSPACE_ROOT_FILE
    : > "$(aiur_crash_marker_path)"
    cmd_stop

    # A similarly named handoff outside this run's runtime directory cannot
    # be used to infer a pidfile, even if an old record contains that path.
    AIUR_WORKSPACE_ROOT_FILE="$ROOT/aiur-202-workspace-root"
    write_aiur_instance_record aiur-test-default aiur-test
    grep -v '^AIUR_RECORD_AGENT_TMPFILE=' "$(aiur_instance_record_path)" > "$STATE/legacy-record"
    mv "$STATE/legacy-record" "$(aiur_instance_record_path)"
    unset AIUR_WORKSPACE_ROOT_FILE
    ! agent_pidfile_from_instance_record > /dev/null
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
          {"HANDOFF", handoff},
          {"STATE", state},
          {"EVENTS", events},
          {"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}
        ],
        stderr_to_stdout: true
      )

    assert length(String.split(output, "REAP:#{target}\n")) == 4
    refute output =~ "REAP:#{sibling}\n"
    refute File.exists?(target)
    assert File.read!(sibling) == "pid 202 codex\n"
  end

  test "stop for instance A reaps A's child and spares B's" do
    root = Aiur.TestSupport.tmp_root!("aiur-stop-process")
    runtime = Path.join(root, "runtime")
    children = Path.join(root, "children")
    File.mkdir_p!(runtime)
    File.write!(children, "")

    on_exit(fn ->
      System.cmd("bash", [
        "-c",
        ~S"""
        source "$1"
        while read -r kind pid comm; do
          if agent_pid_matches "$pid" "$comm"; then kill -KILL "$pid" 2>/dev/null || true; fi
        done < "$2"
        """,
        "--",
        @engine,
        children
      ])

      File.rm_rf!(root)
    end)

    script = ~S"""
    source "$AIUR_ENGINE"
    resolve_release() { :; }
    aiur_resolve_identity() { :; }
    probe_node_liveness() { printf up; }
    kill_beams_matching() { :; }
    reap_workspace_cwd_from_file() { :; }
    reap_stale_manual_smoke() { :; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    warn_other_aiur_daemons() { :; }
    tmux() { return 1; }
    AIUR_PROJECT_ROOT="$ROOT"
    AIUR_PROJECT_ROOT_SOURCE=env

    # Future-regression witness for #2846; matching-command PID recycling (#2844) is out of scope.
    for instance in a b; do
      comm="aiur-stop-witness-$instance"
      bash -c 'exec -a "$1" sleep 300' -- "$comm" > /dev/null 2>&1 &
      pid=$!
      printf 'pid %s %s\n' "$pid" "$comm" >> "$CHILDREN"
      AIUR_INSTANCE_KEY="$instance"
      AIUR_RELEASE_NODE="aiur-stop-witness-$instance@127.0.0.1"
      AIUR_AGENT_TMPFILE="$XDG_RUNTIME_DIR/aiur-$pid-agents"
      printf 'pid %s %s\n' "$pid" "$comm" > "$AIUR_AGENT_TMPFILE"
      write_aiur_instance_record "aiur-$instance-default" "aiur-$instance"
      # Wait until exec has installed the command the real PID matcher checks.
      for attempt in {1..50}; do
        agent_pid_matches "$pid" "$comm" && break
        sleep 0.1
      done
      agent_pid_matches "$pid" "$comm"
      if [ "$instance" = a ]; then a=$pid; target=$AIUR_AGENT_TMPFILE
      else b=$pid; sibling=$AIUR_AGENT_TMPFILE; sibling_record=$(aiur_instance_record_path); fi
    done
    unset AIUR_AGENT_TMPFILE
    AIUR_INSTANCE_KEY=a
    AIUR_RELEASE_NODE=aiur-stop-witness-a@127.0.0.1
    cmd_stop
    for attempt in {1..50}; do
      kill -0 "$a" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$a" 2>/dev/null; then echo 'A survived stop' >&2; exit 1; fi
    wait "$a" 2>/dev/null || true
    agent_pid_matches "$b" aiur-stop-witness-b
    [ ! -e "$target" ]
    [ -f "$sibling_record" ]
    [ "$(cat "$sibling")" = "pid $b aiur-stop-witness-b" ]
    printf 'A exited; B alive; B record and pidfile preserved\n'
    """

    {output, status} =
      System.cmd("bash", ["-c", "set -euo pipefail\n" <> script],
        env: [
          {"AIUR_ENGINE", @engine},
          {"AIUR_BG_STATE_DIR", Path.join(root, "state")},
          {"AIUR_SESSION_PREFIX", "aiur"},
          {"XDG_RUNTIME_DIR", runtime},
          {"ROOT", root},
          {"CHILDREN", children}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "A exited; B alive; B record and pidfile preserved"
  end
end
