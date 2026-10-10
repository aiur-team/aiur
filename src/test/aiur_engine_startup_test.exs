defmodule AiurEngineStartupTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "background startup waits until the control plane is ready" do
    tmux = fake_tmux_script("exit 0")
    capture = Aiur.TestSupport.tmp_root!("aiur-startup")
    counter = Aiur.TestSupport.tmp_root!("aiur-control-probes")
    File.write!(capture, "")
    File.write!(counter, "0")

    on_exit(fn ->
      File.rm(capture)
      File.rm(counter)
    end)

    script = """
    sleep() { :; }
    probe_control_liveness() {
      calls="$(cat "$COUNTER")"
      calls=$((calls + 1))
      printf '%s' "$calls" > "$COUNTER"
      if [ "$calls" -lt 3 ]; then printf down; else printf up; fi
    }
    wait_for_session_startup "$FAKE_TMUX" sock conf session "$CAPTURE" 1
    echo "CALLS=$(cat "$COUNTER")"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"FAKE_TMUX", tmux},
        {"CAPTURE", capture},
        {"COUNTER", counter},
        {"AIUR_NODE_GRACE_TICKS", "5"}
      ])

    assert out =~ "CALLS=3"
  end

  test "background startup fails when the node never registers" do
    tmux = fake_tmux_script("exit 0")
    capture = Aiur.TestSupport.tmp_root!("aiur-startup")
    File.write!(capture, "node boot log\n")
    on_exit(fn -> File.rm(capture) end)

    script = """
    sleep() { :; }
    probe_control_liveness() { printf down; }
    set +e
    wait_for_session_startup "$FAKE_TMUX" sock conf session "$CAPTURE" 1
    code=$?
    set -e
    echo "CODE=$code"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"FAKE_TMUX", tmux},
        {"CAPTURE", capture},
        {"AIUR_NODE_GRACE_TICKS", "2"},
        {"RELEASE_NODE", "aiur-test@127.0.0.1"}
      ])

    assert out =~ "CODE=1"
    assert out =~ "aiur control plane at aiur-test@127.0.0.1 was still booting"
    assert out =~ "node boot log"
  end

  test "startup wait reports tmux exits with captured output" do
    tmux = fake_tmux_script(~s|case " $* " in *" has-session "*) exit 1 ;; *) exit 0 ;; esac|)
    capture = Aiur.TestSupport.tmp_root!("aiur-startup")
    File.write!(capture, "boot failed\n")
    on_exit(fn -> File.rm(capture) end)

    script = """
    sleep() { :; }
    probe_control_liveness() { printf up; }
    set +e
    wait_for_session_startup "$FAKE_TMUX" sock conf session "$CAPTURE" 1
    code=$?
    set -e
    echo "CODE=$code"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"FAKE_TMUX", tmux},
        {"CAPTURE", capture},
        {"AIUR_NODE_GRACE_TICKS", "2"}
      ])

    assert out =~ "CODE=1"
    assert out =~ "aiur exited during startup"
    assert out =~ "boot failed"
  end

  # A daemon that is merely slow used to be reported exactly like a crashed
  # one -- with an empty capture, because there was no failure to print. That
  # sent debugging after a broken release instead of a short timeout.
  test "startup wait distinguishes a still-booting control plane from a crash" do
    tmux = fake_tmux_script("exit 0")
    capture = Aiur.TestSupport.tmp_root!("aiur-startup")
    File.write!(capture, "")
    on_exit(fn -> File.rm(capture) end)

    script = """
    sleep() { :; }
    probe_control_liveness() { printf down; }
    set +e
    wait_for_session_startup "$FAKE_TMUX" sock conf session "$CAPTURE" 1
    code=$?
    set -e
    echo "CODE=$code"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"FAKE_TMUX", tmux},
        {"CAPTURE", capture},
        {"AIUR_NODE_GRACE_TICKS", "2"}
      ])

    assert out =~ "CODE=1"
    assert out =~ "was still booting"
    assert out =~ "the BEAM is alive but not yet answering"
    assert out =~ "AIUR_NODE_GRACE_TICKS"
    refute out =~ "did not become ready"
  end

  # The 10s budget this replaced was short enough that a healthy daemon lost
  # the race on a cold boot, so guard the floor rather than the exact value.
  test "startup wait keeps a generous default control-plane budget" do
    source = Aiur.EngineSource.text()
    [_, ticks] = Regex.run(~r/AIUR_NODE_GRACE_TICKS:-(\d+)/, source)
    assert String.to_integer(ticks) >= 600
  end

  test "background startup failure cleans generated tempfiles and reaps session" do
    rel = fake_release()
    state = tmp_state()
    tmp = Aiur.TestSupport.tmp_root!("aiur-bg-fail")
    events = Aiur.TestSupport.tmp_root!("aiur-events")
    tmux_state = Path.join(tmp, "tmux-session")
    dump = Path.join(tmp, "erl_crash.dump")
    ledger = Path.join(tmp, "alerts.ndjson")
    File.mkdir_p!(tmp)
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*) touch "#{tmux_state}"; exit 0 ;;
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *" kill-session "*) echo "KILL_SESSION:$*" >> "#{events}"; rm -f "#{tmux_state}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(tmp)
      File.rm(events)
    end)

    script = """
    export TMPDIR="$TMP_ROOT"
    export XDG_RUNTIME_DIR="$TMP_ROOT"
    mktemp() {
      case "$1" in
        */aiur-argv.*) path="$TMP_ROOT/argv" ;;
        */aiur-startup.*) path="$TMP_ROOT/startup" ;;
        */aiur-pane.*) path="$TMP_ROOT/launcher" ;;
        *) command mktemp "$@" ;;
      esac
      : > "$path"
      printf '%s\\n' "$path"
    }
    sleep() { :; }
    probe_control_liveness() {
      printf '%s\n' "$LEDGER" > "$AIUR_ALERT_LEDGER_PATH_FILE"
      printf '=erl_crash_dump:0.5\nSlogan: startup exploded\n=end\n' > "$ERL_CRASH_DUMP"
      printf down
    }
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    expected_session="$TMP_ROOT/aiur-$$-sessions"
    expected_agents="$TMP_ROOT/aiur-$$-agents"
    expected_workspace_root="$TMP_ROOT/aiur-$$-workspace-root"
    expected_alert_ledger="$TMP_ROOT/aiur-$$-alert-ledger"
    expected_dump_baseline="$TMP_ROOT/aiur-$$-crash-dump-baseline"
    set +e
    ( run_session background )
    code=$?
    set -e
    echo "CODE=$code"
    for path in "$TMP_ROOT/argv" "$TMP_ROOT/startup" "$TMP_ROOT/launcher" "$expected_session" "$expected_agents" "$expected_workspace_root" "$expected_alert_ledger" "$expected_dump_baseline"; do
      if [ -e "$path" ]; then echo "LEFT:${path##*/}"; else echo "REMOVED:${path##*/}"; fi
    done
    cat "$EVENTS"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"AIUR_NODE_GRACE_TICKS", "2"},
        {"EVENTS", events},
        {"ERL_CRASH_DUMP", dump},
        {"LEDGER", ledger},
        {"PATH", path},
        {"TMP_ROOT", tmp}
      ])

    assert out =~ "CODE=1"
    assert out =~ "KILL_SESSION:"
    assert out =~ "REAP:aiur-"
    assert out =~ "KILL_BEAM:-name aiur-"
    assert out =~ "REMOVED:argv"
    assert out =~ "REMOVED:startup"
    assert out =~ "REMOVED:launcher"
    assert out =~ "REMOVED:aiur-"
    refute out =~ "LEFT:"

    [alert] = ledger |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert alert["topic"] == "system.beam.crash_dump"
    assert alert["slogan"] == "startup exploded"
  end

  test "foreground startup failure before control readiness exits nonzero and preserves output" do
    rel = fake_release()
    state = tmp_state()
    tmp = Aiur.TestSupport.tmp_root!("aiur-fg-fail")
    events = Aiur.TestSupport.tmp_root!("aiur-events")
    tmux_state = Path.join(tmp, "tmux-session")
    File.mkdir_p!(tmp)
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*)
          touch "#{tmux_state}"
          echo "Failed to start Aiur with workflow test-config" >> "#{Path.join(tmp, "startup")}"
          exit 0
          ;;
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *" attach "*) echo "ATTACH:$*" >> "#{events}"; exit 0 ;;
        *" kill-session "*) echo "KILL_SESSION:$*" >> "#{events}"; rm -f "#{tmux_state}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(tmp)
      File.rm(events)
    end)

    script = """
    export TMPDIR="$TMP_ROOT"
    export XDG_RUNTIME_DIR="$TMP_ROOT"
    mktemp() {
      case "$1" in
        */aiur-argv.*) path="$TMP_ROOT/argv" ;;
        */aiur-startup.*) path="$TMP_ROOT/startup" ;;
        */aiur-pane.*) path="$TMP_ROOT/launcher" ;;
        */aiur-attach.*) path="$TMP_ROOT/attach" ;;
        *) command mktemp "$@"; return ;;
      esac
      : > "$path"
      printf '%s\\n' "$path"
    }
    sleep() { :; }
    probe_control_liveness() { printf down; }
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    set +e
    ( run_session foreground )
    code=$?
    set -e
    echo "CODE=$code"
    cat "$EVENTS"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"AIUR_NODE_GRACE_TICKS", "2"},
        {"EVENTS", events},
        {"PATH", path},
        {"TMP_ROOT", tmp}
      ])

    assert out =~ "CODE=1"
    assert out =~ ~r/aiur control plane at aiur-enginetest-\d+@127\.0\.0\.1 was still booting/
    assert out =~ "Failed to start Aiur with workflow test-config"
    assert out =~ "KILL_SESSION:"
    assert out =~ "REAP:aiur-"
    assert out =~ "KILL_BEAM:-name aiur-"
    refute out =~ "ATTACH:"
  end
end
