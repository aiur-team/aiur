defmodule AiurEngineWatchdogTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "seeded BEAM watchdog reaps immediately when the node disappears" do
    events = Aiur.TestSupport.tmp_root!("aiur-events")
    File.write!(events, "")
    on_exit(fn -> File.rm(events) end)

    script = """
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    pattern="aiur-watchdog-${$}-absent"
    first_pid="$(start_beam_death_watchdog "$pattern" sock pidfile 0.05 1)"
    for _ in $(seq 1 20); do
      [ -s "$EVENTS" ] && break
      sleep 0.05
    done
    kill "$first_pid" 2>/dev/null || true
    echo "SEEDED=$(cat "$EVENTS")"

    : > "$EVENTS"
    second_pid="$(start_beam_death_watchdog "$pattern" sock pidfile 0.05 0)"
    sleep 0.15
    if [ -s "$EVENTS" ]; then echo "DEFAULT_REAPED"; else echo "DEFAULT_WAITED"; fi
    kill "$second_pid" 2>/dev/null || true
    """

    {out, 0} = run_sourced_engine(script, [{"EVENTS", events}])

    assert out =~ "SEEDED=REAP:sock pidfile"
    assert out =~ "DEFAULT_WAITED"
    refute out =~ "DEFAULT_REAPED"
  end

  test "crash recording emits a bounded needs-attention alert for a completed dump" do
    root = Aiur.TestSupport.tmp_root!("aiur-crash-alert")
    run_log_dir = Path.join(root, "run")
    dump = Path.join(root, "erl_crash.dump")
    marker = Path.join(root, "last-crash")
    ledger = Path.join(root, "aiur.alerts.ndjson")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    slogan = ~s(Failed to read from erl_child_setup: 104 "quoted" \\ #{String.duplicate("x", 700)})
    File.mkdir_p!(root)
    File.write!(dump, "=erl_crash_dump:0.5\nSlogan: #{slogan}\n=end\n")
    File.write!(ledger_path_file, ledger)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {_out, 0} =
             run_sourced_engine(
               ~S|record_beam_crash "aiur-test@127.0.0.1" "$RUN_LOG_DIR" "$CRASH_MARKER" "$LEDGER_PATH_FILE"|,
               [
                 {"RUN_LOG_DIR", run_log_dir},
                 {"CRASH_MARKER", marker},
                 {"ERL_CRASH_DUMP", dump},
                 {"LEDGER_PATH_FILE", ledger_path_file}
               ]
             )

    [alert] =
      ledger
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert alert["event"] == "alert"
    assert alert["agent"] == "system"
    assert alert["topic"] == "system.beam.crash_dump"
    assert alert["needs_attention"] == true
    assert alert["severity"] == "warning"
    assert alert["dump_path"] == dump
    assert alert["message"] =~ "Failed to read from erl_child_setup: 104"
    assert alert["slogan"] =~ ~s("quoted" \\)
    assert byte_size(alert["slogan"]) <= 512
    assert Enum.any?(Aiur.AlertFeed.list(ledger_paths: [ledger]), &(&1["topic"] == "system.beam.crash_dump"))
    assert File.read!(Path.join(run_log_dir, "log/aiur.crash")) =~ "crash_dump_slogan:"
  end

  test "crash recording does not alert for an incomplete dump" do
    root = Aiur.TestSupport.tmp_root!("aiur-incomplete-dump")
    run_log_dir = Path.join(root, "run")
    dump = Path.join(root, "erl_crash.dump")
    ledger = Path.join(root, "aiur.alerts.ndjson")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    File.mkdir_p!(root)
    File.write!(dump, "=erl_crash_dump:0.5\nSlogan: still being written\n")
    File.write!(ledger_path_file, ledger)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {_out, 0} =
             run_sourced_engine(
               ~S|record_beam_crash "aiur-test@127.0.0.1" "$RUN_LOG_DIR" "" "$LEDGER_PATH_FILE"|,
               [
                 {"RUN_LOG_DIR", run_log_dir},
                 {"ERL_CRASH_DUMP", dump},
                 {"LEDGER_PATH_FILE", ledger_path_file}
               ]
             )

    refute File.exists?(ledger)
  end

  test "crash recording does not alert when the configured dump is missing" do
    root = Aiur.TestSupport.tmp_root!("aiur-missing-dump")
    ledger = Path.join(root, "aiur.alerts.ndjson")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    File.mkdir_p!(root)
    File.write!(ledger_path_file, ledger)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {_out, 0} =
             run_sourced_engine(
               ~S|record_beam_crash "aiur-test@127.0.0.1" "" "" "$LEDGER_PATH_FILE"|,
               [
                 {"ERL_CRASH_DUMP", Path.join(root, "missing.dump")},
                 {"LEDGER_PATH_FILE", ledger_path_file}
               ]
             )

    refute File.exists?(ledger)
  end

  test "crash recording ignores a completed dump unchanged since launch" do
    root = Aiur.TestSupport.tmp_root!("aiur-stale-dump")
    run_log_dir = Path.join(root, "run")
    dump = Path.join(root, "erl_crash.dump")
    ledger = Path.join(root, "aiur.alerts.ndjson")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    baseline_file = Path.join(root, "dump-baseline")
    File.mkdir_p!(root)
    File.write!(dump, "=erl_crash_dump:0.5\nSlogan: stale evidence\n=end\n")
    File.write!(ledger_path_file, ledger)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {_out, 0} =
             run_sourced_engine(
               ~S|crash_dump_identity "$ERL_CRASH_DUMP" >"$BASELINE_FILE"; record_beam_crash test "$RUN_LOG_DIR" "" "$LEDGER_PATH_FILE" "$BASELINE_FILE"|,
               [
                 {"RUN_LOG_DIR", run_log_dir},
                 {"ERL_CRASH_DUMP", dump},
                 {"LEDGER_PATH_FILE", ledger_path_file},
                 {"BASELINE_FILE", baseline_file}
               ]
             )

    refute File.exists?(ledger)
    refute File.read!(Path.join(run_log_dir, "log/aiur.crash")) =~ "crash_dump_slogan:"
  end

  test "watchdog still reaps when the alert ledger cannot be written" do
    root = Aiur.TestSupport.tmp_root!("aiur-alert-failure")
    events = Path.join(root, "events")
    dump = Path.join(root, "erl_crash.dump")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    File.mkdir_p!(root)
    File.write!(events, "")
    File.write!(dump, "=erl_crash_dump:0.5\nSlogan: write failure\n=end\n")
    File.write!(ledger_path_file, root)
    on_exit(fn -> File.rm_rf!(root) end)

    script = """
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    reap_workspace_cwd_from_file() { echo "SWEEP:$*" >> "$EVENTS"; }
    pattern="aiur-watchdog-${$}-absent"
    pid="$(start_beam_death_watchdog "$pattern" sock pidfile 0.05 1 test "$RUN_LOG_DIR" "" "$CRASH_MARKER" "" "$LEDGER_PATH_FILE" "")"
    for _ in $(seq 1 20); do
      grep -q '^SWEEP:' "$EVENTS" && break
      sleep 0.05
    done
    kill "$pid" 2>/dev/null || true
    cat "$EVENTS"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"EVENTS", events},
        {"RUN_LOG_DIR", Path.join(root, "run")},
        {"CRASH_MARKER", Path.join(root, "marker")},
        {"ERL_CRASH_DUMP", dump},
        {"LEDGER_PATH_FILE", ledger_path_file}
      ])

    assert out =~ "REAP:sock pidfile"
    assert out =~ "SWEEP:"
  end

  test "foreground watchdog alerts for a byte-identical replacement and removes handoffs" do
    root = Aiur.TestSupport.tmp_root!("aiur-foreground-crash")
    events = Path.join(root, "events")
    dump = Path.join(root, "erl_crash.dump")
    ledger = Path.join(root, "aiur.alerts.ndjson")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    baseline_file = Path.join(root, "dump-baseline")
    File.mkdir_p!(root)
    File.write!(events, "")
    File.write!(dump, "=erl_crash_dump:0.5\nSlogan: recurring crash\n=end\n")
    File.write!(ledger_path_file, ledger)
    on_exit(fn -> File.rm_rf!(root) end)

    script = """
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    reap_workspace_cwd_from_file() { echo "SWEEP:$*" >> "$EVENTS"; }
    crash_dump_identity "$ERL_CRASH_DUMP" > "$BASELINE_FILE"
    cp "$ERL_CRASH_DUMP" "$ERL_CRASH_DUMP.replacement"
    mv "$ERL_CRASH_DUMP.replacement" "$ERL_CRASH_DUMP"
    pattern="aiur-watchdog-${$}-absent"
    pid="$(start_beam_death_watchdog "$pattern" sock pidfile 0.05 1 foreground-node "" "" "" "" "$LEDGER_PATH_FILE" "$BASELINE_FILE")"
    for _ in $(seq 1 20); do
      [ -s "$LEDGER" ] && [ ! -e "$LEDGER_PATH_FILE" ] && [ ! -e "$BASELINE_FILE" ] && break
      sleep 0.05
    done
    kill "$pid" 2>/dev/null || true
    cat "$EVENTS"
    [ -s "$LEDGER" ] && echo ALERTED
    [ ! -e "$LEDGER_PATH_FILE" ] && echo LEDGER_HANDOFF_REMOVED
    [ ! -e "$BASELINE_FILE" ] && echo BASELINE_REMOVED
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"EVENTS", events},
        {"ERL_CRASH_DUMP", dump},
        {"LEDGER", ledger},
        {"LEDGER_PATH_FILE", ledger_path_file},
        {"BASELINE_FILE", baseline_file}
      ])

    assert out =~ "REAP:sock pidfile"
    assert out =~ "ALERTED"
    assert out =~ "LEDGER_HANDOFF_REMOVED"
    assert out =~ "BASELINE_REMOVED"
    [alert] = ledger |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert alert["slogan"] == "recurring crash"
  end

  test "background run arms the detached BEAM watchdog before success" do
    rel = fake_release()
    state = tmp_state()
    logs = Path.join(state, "logs")
    tmux_state = Aiur.TestSupport.tmp_root!("aiur-tmux-state")
    events = Aiur.TestSupport.tmp_root!("aiur-events")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*)
          printf '%s\n' '__AIUR_CONFIG_PATH__:/tmp/project config/.aiur/config' >> "#{logs}/log/boot.out.log"
          touch "#{tmux_state}"
          exit 0
          ;;
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(tmux_state)
      File.rm(events)
    end)

    script = """
    sleep() { :; }
    kill_beams_matching() { :; }
    preflight_stale_manual_smoke() { :; }
    probe_control_liveness() {
      echo PROBE >> "$EVENTS"
      printf up
    }
    probe_dashboard_status() { printf 'Dashboard: http://127.0.0.1:4567 (bind host=127.0.0.1, port=4567)'; }
    start_beam_death_watchdog() {
      echo "WATCHDOG:$*" >> "$EVENTS"
      printf '424242\\n'
    }
    disown() { echo "DISOWN:$*" >> "$EVENTS"; }
    aiur_engine_main run --bg
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"XDG_RUNTIME_DIR", state},
        {"HOME", state},
        {"AIUR_LOGS_ROOT", logs},
        {"AIUR_NODE_GRACE_TICKS", "2"},
        {"EVENTS", events},
        {"PATH", path}
      ])

    assert out =~ "aiur started in the background"

    assert out =~
             ~r/Config: \/tmp\/project config\/\.aiur\/config\nDashboard: http:\/\/127\.0\.0\.1:4567.*\naiur started in the background/s

    events_log = File.read!(events)
    assert events_log =~ "PROBE\nWATCHDOG:-name aiur-"

    assert events_log =~
             ~r/ 1 1 aiur-\S+ \S+ \S+\.stopping \S+\.last-crash \S+-workspace-root \S+-alert-ledger \S+-crash-dump-baseline\n/

    assert events_log =~ "DISOWN:424242"
  end

  test "background launch with --no-dashboard in either-order form reports explicit suppression" do
    rel = fake_release()
    state = tmp_state()
    logs = Path.join(state, "logs")
    tmux_state = Aiur.TestSupport.tmp_root!("aiur-tmux-state")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*)
          printf '%s\n' '__AIUR_CONFIG_PATH__:/tmp/project config/.aiur/config' >> "#{logs}/log/boot.out.log"
          touch "#{tmux_state}"
          exit 0
          ;;
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(tmux_state)
    end)

    script = """
    sleep() { :; }
    kill_beams_matching() { :; }
    preflight_stale_manual_smoke() { :; }
    probe_control_liveness() { printf up; }
    probe_dashboard_status() { :; }
    start_beam_death_watchdog() { printf '424242\n'; }
    disown() { :; }
    aiur_engine_main --no-dashboard --bg
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"XDG_RUNTIME_DIR", state},
        {"HOME", state},
        {"AIUR_LOGS_ROOT", logs},
        {"PATH", path}
      ])

    assert out =~
             ~r/Config: \/tmp\/project config\/\.aiur\/config\nDashboard disabled by --no-dashboard\.\naiur started in the background/s

    refute out =~ "dashboard listener unavailable"
  end
end
