defmodule AiurEngineStopTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "stop does not terminate sibling instances from the same release dir" do
    rel = fake_release()
    File.mkdir_p!(Path.join([rel, "erts-16.4", "bin"]))

    state = tmp_state()
    events = Aiur.TestSupport.tmp_root!("aiur-events")

    sibling_marker =
      "#{Path.join([rel, "erts-16.4", "bin", "beam.smp"])} -name aiur-sibling-#{System.unique_integer([:positive])}@127.0.0.1"

    File.write!(events, "")
    tmux = fake_tmux_script("exit 0")

    on_exit(fn ->
      System.cmd("pkill", ["-f", sibling_marker], stderr_to_stdout: true)
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(events)
    end)

    script = """
    bash -c 'exec -a "$SIBLING_MARKER" sleep 20' >/dev/null 2>&1 &
    sibling_pid=$!
    for _ in $(seq 1 20); do
      pgrep -f -- "$SIBLING_MARKER" >/dev/null && break
      sleep 0.05
    done
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    reap_aiur_agents() { :; }
    cmd_stop
    if kill -0 "$sibling_pid" 2>/dev/null; then echo "SIBLING_ALIVE"; else echo "SIBLING_DEAD"; fi
    kill "$sibling_pid" 2>/dev/null || true
    cat "$EVENTS"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"EVENTS", events},
        {"PATH", path},
        {"SIBLING_MARKER", sibling_marker},
        {"USER", "tester"}
      ])

    assert out =~ "SIBLING_ALIVE"
    refute out =~ "SIBLING_DEAD"
    assert out =~ "KILL_BEAM:-name aiur-"
  end

  test "cmd_stop marks a clean stop before killing the BEAM and cwd sweep" do
    state = tmp_state()
    events = Aiur.TestSupport.tmp_root!("aiur-events")
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-workspaces")
    workspace_root_file = Aiur.TestSupport.tmp_root!("aiur-workspace-root")
    record = Aiur.TestSupport.tmp_root!("aiur-stop-record")
    File.mkdir_p!(workspace_root)
    File.write!(workspace_root_file, workspace_root <> "\n")

    File.write!(
      record,
      """
      AIUR_RECORD_NODE=aiur-enginetest@127.0.0.1
      AIUR_RECORD_SESSION=aiur-tester-default
      AIUR_RECORD_SOCKET=aiur-tester
      AIUR_RECORD_PROJECT_ROOT=/tmp/aiur-project
      AIUR_RECORD_WORKSPACE_ROOT_FILE=#{inspect(workspace_root_file)}
      """
    )

    tmux = fake_tmux_script("exit 0")

    on_exit(fn ->
      File.rm_rf(state)
      File.rm_rf(workspace_root)
      File.rm(workspace_root_file)
      File.rm(record)
      File.rm(events)
    end)

    script = """
    resolve_release() { :; }
    aiur_resolve_identity() {
      : "${AIUR_SESSION_PREFIX:=aiur}"
      : "${AIUR_RELEASE_NODE:=aiur-enginetest@127.0.0.1}"
    }
    aiur_instance_record_path() { printf '%s' "$RECORD"; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    reap_aiur_agents() { :; }
    kill_beams_matching() {
      echo "KILL_BEAM:$*" >> "$EVENTS"
      [ -f "$(aiur_stop_sentinel_path)" ] && echo "SENTINEL_PRESENT_BEFORE_KILL" >> "$EVENTS"
      [ ! -f "$(aiur_crash_marker_path)" ] && echo "CRASH_MARKER_CLEARED_BEFORE_KILL" >> "$EVENTS"
    }
    reap_workspace_cwd_agents() { echo "CWD_REAP:$1" >> "$EVENTS"; }
    mkdir -p "$AIUR_BG_STATE_DIR"
    echo stale >"$(aiur_crash_marker_path)"
    cmd_stop
    cat "$EVENTS"
    [ -f "$(aiur_stop_sentinel_path)" ] && echo "SENTINEL_LEFT_FOR_WATCHDOG"
    [ -e "$(aiur_crash_marker_path)" ] && echo "CRASH_MARKER_STILL_PRESENT" || echo "CRASH_MARKER_REMOVED"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_BG_STATE_DIR", state},
        {"EVENTS", events},
        {"PATH", path},
        {"RECORD", record},
        {"USER", "tester"}
      ])

    assert out =~ "SENTINEL_PRESENT_BEFORE_KILL"
    assert out =~ "CRASH_MARKER_CLEARED_BEFORE_KILL"
    assert out =~ "CWD_REAP:#{workspace_root}"
    assert out =~ "SENTINEL_LEFT_FOR_WATCHDOG"
    assert out =~ "CRASH_MARKER_REMOVED"
    refute out =~ "CRASH_MARKER_STILL_PRESENT"
  end

  test "cmd_stop still tears down the session without a workspace root handoff" do
    state = tmp_state()
    events = Aiur.TestSupport.tmp_root!("aiur-stop-timeout")
    File.write!(events, "")

    on_exit(fn ->
      File.rm_rf(state)
      File.rm(events)
    end)

    script = """
    resolve_release() { :; }
    aiur_resolve_identity() {
      : "${AIUR_SESSION_PREFIX:=aiur}"
      : "${AIUR_RELEASE_NODE:=aiur-enginetest@127.0.0.1}"
    }
    resolve_control_identity_from_records() { AIUR_CONTROL_ADOPTED_RECORD=0; AIUR_CONTROL_CURRENT_NODE_STATE=up; }
    workspace_root_file_from_instance_record() { return 1; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    reap_aiur_agents() { :; }
    reap_workspace_cwd_agents() { echo "CWD_REAP:$1" >> "$EVENTS"; }
    cmd_stop
    cat "$EVENTS"
    """

    {out, 0} = run_sourced_engine(script, [{"AIUR_BG_STATE_DIR", state}, {"EVENTS", events}])

    assert out =~ "KILL_BEAM:-name aiur-enginetest-"
  end

  test "cmd_stop gives the BEAM a generous TERM grace so its own agent reap completes" do
    # The stop path must not SIGKILL the BEAM at the 3s startup-reclaim default:
    # the BEAM's graceful shutdown (ProcessReaper reaping the agent tree plus the
    # BEAM-side workspace sweep) takes longer than 3s, and a SIGKILL mid-cleanup is
    # what orphaned agent processes on `aiur stop` / `aiur restart`. Assert the
    # stop grace (default 300 ticks = 30s) is passed through to kill_beams_matching.
    state = tmp_state()
    events = Aiur.TestSupport.tmp_root!("aiur-stop-grace")
    File.write!(events, "")

    on_exit(fn ->
      File.rm_rf(state)
      File.rm(events)
    end)

    script = """
    resolve_release() { :; }
    aiur_resolve_identity() {
      : "${AIUR_SESSION_PREFIX:=aiur}"
      : "${AIUR_RELEASE_NODE:=aiur-enginetest@127.0.0.1}"
    }
    resolve_control_identity_from_records() { AIUR_CONTROL_ADOPTED_RECORD=0; AIUR_CONTROL_CURRENT_NODE_STATE=up; }
    workspace_root_file_from_instance_record() { return 1; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    reap_aiur_agents() { :; }
    reap_workspace_cwd_agents() { :; }
    cmd_stop
    cat "$EVENTS"
    """

    {out, 0} = run_sourced_engine(script, [{"AIUR_BG_STATE_DIR", state}, {"EVENTS", events}])

    assert out =~ ~r/KILL_BEAM:-name aiur-enginetest-.* 300/
  end

  test "kill_beams_matching honors a caller-supplied TERM grace" do
    events = Aiur.TestSupport.tmp_root!("aiur-grace")
    File.write!(events, "")
    on_exit(fn -> File.rm(events) end)

    script = """
    pgrep() { printf '4242\n'; }
    kill() { printf 'KILL:%s\n' "$*" >> "$EVENTS"; }
    sleep() { printf 'SLEEP:%s\n' "$*" >> "$EVENTS"; }
    kill_beams_matching 'aiur-grace' 10
    cat "$EVENTS"
    """

    {out, 0} = run_sourced_engine(script, [{"EVENTS", events}])

    assert length(Regex.scan(~r/^SLEEP:0\.1$/m, out)) == 10
    assert out =~ "KILL:-TERM 4242"
    assert out =~ "KILL:-KILL 4242"
  end

  test "kill_beams_matching falls back deterministically for invalid grace values" do
    events = Aiur.TestSupport.tmp_root!("aiur-invalid-grace")
    File.write!(events, "")
    on_exit(fn -> File.rm(events) end)

    script = """
    pgrep() { printf '4242\n'; }
    kill() { printf 'KILL:%s\n' "$*" >> "$EVENTS"; }
    sleep() { printf 'SLEEP:%s\n' "$*" >> "$EVENTS"; }
    kill_beams_matching 'aiur-grace' -1
    printf 'NEXT\n' >> "$EVENTS"
    kill_beams_matching 'aiur-grace' oops
    printf 'NEXT\n' >> "$EVENTS"
    kill_beams_matching 'aiur-grace' 999999999999999999999999999999999999
    cat "$EVENTS"
    """

    {out, 0} = run_sourced_engine(script, [{"EVENTS", events}])

    assert length(Regex.scan(~r/^SLEEP:0\.1$/m, out)) == 90
    assert length(Regex.scan(~r/^KILL:-TERM 4242$/m, out)) == 3
    assert length(Regex.scan(~r/^KILL:-KILL 4242$/m, out)) == 3
    assert length(Regex.scan(~r/^NEXT$/m, out)) == 2
  end

  test "cmd_stop fails loud instead of no-oping for an unmatched global-config cwd" do
    rel = fake_release()
    state = tmp_state()
    events = Aiur.TestSupport.tmp_root!("aiur-stop-miss-events")
    caller = Aiur.TestSupport.tmp_root!("aiur-stop-miss")
    File.mkdir_p!(caller)
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" has-session "*) exit 1 ;;
        *) echo "TMUX:$*" >> "$EVENTS"; exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(caller)
      File.rm(events)
    end)

    script = """
    cd "$CALLER"
    current_workspace_root() { return 1; }
    probe_node_liveness() { printf down; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    reap_workspace_cwd_agents() { echo "CWD_REAP:$1" >> "$EVENTS"; }
    set +e
    cmd_stop
    code=$?
    set -e
    echo "CODE=$code"
    echo "FOUND_NOTHING=$AIUR_STOP_FOUND_NOTHING"
    cat "$EVENTS"
    [ -e "$(aiur_stop_sentinel_path)" ] && echo "SENTINEL_WRITTEN" || echo "NO_SENTINEL"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"CALLER", caller},
        {"EVENTS", events},
        {"PATH", path},
        {"AIUR_RELEASE_NODE", nil},
        {"AIUR_INSTANCE_KEY", nil},
        {"AIUR_REPO_ROOT", nil}
      ])

    assert out =~ "CODE=1"
    # The flag restart reads to tell this benign nonzero apart from a real
    # stop failure; `aiur stop`'s own exit code is unchanged.
    assert out =~ "FOUND_NOTHING=1"
    assert out =~ "nothing stopped"
    refute out =~ "global-config control identity is keyed by cwd"
    assert out =~ "NO_SENTINEL"
    refute out =~ "KILL_BEAM:"
    refute out =~ "CWD_REAP:"
  end

  test "message RPCs the message expression with base64-encoded text" do
    rel = fake_release()

    {out, _} =
      run_engine_real(
        ["message", "44", "ship it"],
        [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}]
      )

    encoded = Base.encode64("ship it")
    assert out =~ ~s|Aiur.AgentControlCLI.message("44", Base.decode64!("#{encoded}"))|
  end

  test "message base64-transports hostile text so it cannot break the RPC expression" do
    rel = fake_release()
    # Quotes, backslash, Elixir interpolation, and a newline — the exact characters
    # the base64 hop exists to neutralize.
    hostile = ~s|say "hi" #{"\#{System.halt}"} \\o/| <> "\nline2"

    {out, _} =
      run_engine_real(
        ["message", "44", hostile],
        [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}]
      )

    assert out =~ ~s|Aiur.AgentControlCLI.message("44", Base.decode64!("#{Base.encode64(hostile)}"))|
    # The raw text never reaches the expression un-encoded.
    refute out =~ ~s|say "hi"|
    refute out =~ "System.halt"
  end

  test "message without text exits 64 with guidance" do
    {out, code} = run_engine_real(["message", "44"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "message expects an issue ID and text"
  end

  test "message with a non-numeric issue id exits 64 with guidance" do
    {out, code} = run_engine_real(["message", "abc", "hi"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "message expects an issue ID and text"
  end

  test "message without an issue exits 64 with guidance" do
    {out, code} = run_engine_real(["message"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "message expects an issue ID and text"
  end

  # --- stale /tmp artifact reaping (#334) -------------------------------------
  #
  # The reaper only ever scans the temp roots TMPDIR / XDG_RUNTIME_DIR point at,
  # so each test redirects both at a throwaway mktemp dir — the real /tmp is never
  # touched. Old mtimes use `touch -t CCYYMMDDhhmm`, which both GNU and BSD touch
  # accept, so these run identically on Linux CI and macOS dev.

  test "sweep_stale_tmp_artifacts reaps stale known debris and spares live/fresh/non-matching" do
    script = """
    source #{engine()}
    T="$(mktemp -d "${TMPDIR:-/tmp}/aiur-reap-test.XXXXXX")"
    OLD="$(date -d '3 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)"

    touch -t "$OLD" "$T/aiur-argv.STALE"
    touch "$T/aiur-argv.FRESH"
    mkdir -p "$T/aiur-rc"; touch "$T/aiur-rc/live.log"; touch -t "$OLD" "$T/aiur-rc"
    mkdir -p "$T/aiur-debug"; touch -t "$OLD" "$T/aiur-debug/old.log"; touch -t "$OLD" "$T/aiur-debug"
    mkdir -p "$T/aiur-pr123"; touch -t "$OLD" "$T/aiur-pr123/checkout"; touch -t "$OLD" "$T/aiur-pr123"
    mkdir -p "$T/aiur_workspaces/w"; touch -t "$OLD" "$T/aiur_workspaces/w/f"; touch -t "$OLD" "$T/aiur_workspaces"
    mkdir -p "$T/aiur100-hex"; touch -t "$OLD" "$T/aiur100-hex/c"; touch -t "$OLD" "$T/aiur100-hex"
    touch -t "$OLD" "$T/aiur-user-note.txt"
    touch -t "$OLD" "$T/aiur-4000000000-agents"
    touch -t "$OLD" "$T/aiur-4000000000-alert-ledger"
    touch -t "$OLD" "$T/aiur-4000000000-crash-dump-baseline"
    sleep 30 & LIVE=$!
    touch -t "$OLD" "$T/aiur-$LIVE-agents"
    touch -t "$OLD" "$T/aiur-$LIVE-alert-ledger"
    touch -t "$OLD" "$T/aiur-$LIVE-crash-dump-baseline"
    touch -t "$OLD" "$T/unrelated.txt"

    TMPDIR="$T" XDG_RUNTIME_DIR="$T" AIUR_TMP_REAP_MINUTES=60 sweep_stale_tmp_artifacts

    chk(){ if [ "$2" = present ]; then [ -e "$T/$1" ] && echo "PASS $1" || echo "FAIL $1 expected-present"; else [ -e "$T/$1" ] && echo "FAIL $1 expected-gone" || echo "PASS $1"; fi; }
    chk aiur-argv.STALE gone
    chk aiur-argv.FRESH present
    chk aiur-rc present
    chk aiur-debug gone
    chk aiur-pr123 present
    chk aiur_workspaces present
    chk aiur100-hex present
    chk aiur-user-note.txt present
    chk aiur-4000000000-agents gone
    chk aiur-4000000000-alert-ledger gone
    chk aiur-4000000000-crash-dump-baseline gone
    chk "aiur-$LIVE-agents" present
    chk "aiur-$LIVE-alert-ledger" present
    chk "aiur-$LIVE-crash-dump-baseline" present
    chk unrelated.txt present
    kill "$LIVE" 2>/dev/null || true
    rm -rf "$T"
    """

    {out, code} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert code == 0, "fixture script aborted:\n#{out}"
    refute out =~ "FAIL", "unexpected reaper outcome:\n#{out}"

    # Each outcome asserted by name so a regression names exactly what drifted.
    for name <- ~w(aiur-argv.STALE aiur-argv.FRESH aiur-rc aiur-debug aiur_workspaces
                   aiur-pr123 aiur100-hex aiur-user-note.txt aiur-4000000000-agents
                   aiur-4000000000-alert-ledger aiur-4000000000-crash-dump-baseline
                   unrelated.txt) do
      assert out =~ "PASS #{name}", "missing PASS #{name} in:\n#{out}"
    end

    # The live-pid pidfile (name carries a runtime pid) was spared.
    assert out =~ ~r/PASS aiur-\d+-agents/
    assert out =~ ~r/PASS aiur-\d+-alert-ledger/
    assert out =~ ~r/PASS aiur-\d+-crash-dump-baseline/
  end

  test "sweep_stale_tmp_artifacts default window spares artifacts younger than 24h" do
    # A 3-hour-old artifact must survive the conservative 1440-minute default —
    # this is the guard that a same-day dev/test run is never reaped out from under.
    script = """
    source #{engine()}
    T="$(mktemp -d "${TMPDIR:-/tmp}/aiur-reap-default.XXXXXX")"
    OLD="$(date -d '3 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)"
    touch -t "$OLD" "$T/aiur-argv.RECENT"
    TMPDIR="$T" XDG_RUNTIME_DIR="$T" sweep_stale_tmp_artifacts
    [ -e "$T/aiur-argv.RECENT" ] && echo "KEPT" || echo "GONE"
    rm -rf "$T"
    """

    {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert out =~ "KEPT"
    refute out =~ "GONE"
  end

  test "sweep_stale_tmp_artifacts is disabled by a 0 or non-numeric AIUR_TMP_REAP_MINUTES" do
    script = """
    source #{engine()}
    T="$(mktemp -d "${TMPDIR:-/tmp}/aiur-reap-off.XXXXXX")"
    OLD="$(date -d '3 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)"
    touch -t "$OLD" "$T/aiur-argv.STALE"
    TMPDIR="$T" XDG_RUNTIME_DIR="$T" AIUR_TMP_REAP_MINUTES=0 sweep_stale_tmp_artifacts
    [ -e "$T/aiur-argv.STALE" ] && echo "KEPT-ZERO" || echo "GONE-ZERO"
    TMPDIR="$T" XDG_RUNTIME_DIR="$T" AIUR_TMP_REAP_MINUTES=abc sweep_stale_tmp_artifacts
    [ -e "$T/aiur-argv.STALE" ] && echo "KEPT-NAN" || echo "GONE-NAN"
    rm -rf "$T"
    """

    {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert out =~ "KEPT-ZERO"
    assert out =~ "KEPT-NAN"
    refute out =~ "GONE"
  end
end
