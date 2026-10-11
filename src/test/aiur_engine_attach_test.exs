defmodule AiurEngineAttachTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "bare foreground invocation attaches to a live session without taking cleanup ownership" do
    rel = fake_release()
    state = tmp_state()
    tmux_state = Aiur.TestSupport.tmp_root!("aiur-tmux-state")
    events = Aiur.TestSupport.tmp_root!("aiur-events")
    logs = Aiur.TestSupport.tmp_root!("aiur-logs")
    File.write!(tmux_state, "")
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *" new-session "*) echo "NEW_SESSION:$*" >> "#{events}"; exit 0 ;;
        *" attach "*) echo "ATTACH:$*" >> "#{events}"; exit 0 ;;
        *" kill-session "*) echo "KILL_SESSION:$*" >> "#{events}"; exit 0 ;;
        *" kill-server "*) echo "KILL_SERVER:$*" >> "#{events}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(tmux_state)
      File.rm(events)
      File.rm_rf(logs)
    end)

    script = """
    probe_control_liveness() { printf up; }
    start_beam_death_watchdog() { echo "WATCHDOG:$*" >> "$EVENTS"; printf '424242\n'; }
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    run_session foreground --no-dashboard
    cat "$EVENTS"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"AIUR_LOGS_ROOT", logs},
        {"EVENTS", events},
        {"PATH", path}
      ])

    assert out =~ "attaching to the running session"
    assert out =~ "ATTACH:-L"
    refute out =~ "NEW_SESSION:"
    refute out =~ "WATCHDOG:"
    refute out =~ "KILL_SESSION:"
    refute out =~ "KILL_SERVER:"
    refute out =~ "REAP:"
    refute out =~ "KILL_BEAM:"
    refute out =~ "Dashboard disabled"
    refute File.exists?(logs)
  end

  test "existing-session attach failure propagates without teardown or leaked stderr tempfiles" do
    rel = fake_release()
    state = tmp_state()
    tmp = Aiur.TestSupport.tmp_root!("aiur-attach-failure")
    events = Path.join(tmp, "events")
    File.mkdir_p!(tmp)
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" has-session "*) exit 0 ;;
        *" attach "*) echo "[server exited]" >&2; echo "attach failed" >&2; exit 23 ;;
        *" kill-session "*) echo "KILL_SESSION:$*" >> "#{events}"; exit 0 ;;
        *" kill-server "*) echo "KILL_SERVER:$*" >> "#{events}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(tmp)
    end)

    script = """
    probe_control_liveness() { printf up; }
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    set +e
    run_session foreground --no-dashboard
    code=$?
    set -e
    echo "CODE=$code"
    cat "$EVENTS"
    compgen -G "$TMPDIR/aiur-attach-stderr.*" || true
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"EVENTS", events},
        {"PATH", "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"},
        {"TMPDIR", tmp}
      ])

    assert out =~ "CODE=23"
    assert out =~ "attach failed"
    refute out =~ "[server exited]"
    refute out =~ "KILL_SESSION:"
    refute out =~ "KILL_SERVER:"
    refute out =~ "REAP:"
    refute out =~ "KILL_BEAM:"
    refute out =~ "aiur-attach-stderr."
  end

  test "bare foreground invocation attaches only to the current project session" do
    rel = fake_release()
    state = tmp_state()
    base = Aiur.TestSupport.tmp_root!("aiur-projects")
    project_a = Path.join(base, "alpha")
    project_b = Path.join(base, "beta")
    events = Path.join(base, "events")

    for project <- [project_a, project_b] do
      File.mkdir_p!(Path.join(project, ".aiur"))
      File.write!(Path.join([project, ".aiur", "config"]), "")
    end

    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" has-session "*) exit 0 ;;
        *" new-session "*) echo "NEW_SESSION:$*" >> "#{events}"; exit 0 ;;
        *" attach "*) echo "ATTACH:$*" >> "#{events}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(base)
    end)

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"
    user = System.get_env("USER") || "user"

    script = """
    probe_control_liveness() { printf up; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    run_session foreground --no-dashboard
    """

    for project <- [project_a, project_b] do
      assert {_out, 0} =
               run_sourced_engine(script, [
                 {"AIUR_RELEASE_DIR", rel},
                 {"AIUR_BG_STATE_DIR", state},
                 {"AIUR_REPO_ROOT", project},
                 {"AIUR_INSTANCE_KEY", nil},
                 {"EVENTS", events},
                 {"USER", user},
                 {"PATH", path}
               ])
    end

    [attach_a, attach_b] =
      events
      |> File.read!()
      |> String.split("\n", trim: true)

    identity_a = identity([{"AIUR_REPO_ROOT", project_a}])
    identity_b = identity([{"AIUR_REPO_ROOT", project_b}])
    socket_a = "aiur-#{user}-#{identity_a["AIUR_INSTANCE_KEY"]}"
    socket_b = "aiur-#{user}-#{identity_b["AIUR_INSTANCE_KEY"]}"

    assert attach_a =~ "-L #{socket_a} "
    assert attach_a =~ "-t #{socket_a}-default"
    refute attach_a =~ socket_b

    assert attach_b =~ "-L #{socket_b} "
    assert attach_b =~ "-t #{socket_b}-default"
    refute attach_b =~ socket_a

    refute File.read!(events) =~ "NEW_SESSION:"
  end

  test "directory launch lock prevents stale cleanup from racing a cold startup" do
    rel = fake_release()
    state = tmp_state()
    tmp = Aiur.TestSupport.tmp_root!("aiur-launch-lock")
    tmux_state = Path.join(tmp, "tmux-session")
    ready = Path.join(tmp, "ready")
    events = Path.join(tmp, "events")
    File.mkdir_p!(tmp)
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *" attach "*) echo "ATTACH:$*" >> "#{events}"; exit 0 ;;
        *" new-session "*) echo "NEW_SESSION:$*" >> "#{events}"; exit 0 ;;
        *" kill-server "*) echo "KILL_SERVER:$*" >> "#{events}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(tmp)
    end)

    script = """
    aiur_resolve_identity
    lock=$(aiur_launch_lock_path)
    mkdir -p "$(dirname "$lock")"
    mkdir "$lock"
    (
      sleep 0.2
      touch "$TMUX_STATE" "$READY"
      rm -f "$lock/owner"
      rmdir "$lock"
    ) &
    holder=$!
    printf '%s\n' "$holder" > "$lock/owner"
    probe_control_liveness() { if [ -f "$READY" ]; then printf up; else printf down; fi; }
    probe_node_liveness() { printf down; }
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    run_session foreground --no-dashboard
    wait "$holder"
    [ -d "$lock" ] && echo LOCK_LEFT
    cat "$EVENTS"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"EVENTS", events},
        {"PATH", "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"},
        {"READY", ready},
        {"TMUX_STATE", tmux_state}
      ])

    assert out =~ "ATTACH:-L"
    refute out =~ "NEW_SESSION:"
    refute out =~ "KILL_SERVER:"
    refute out =~ "REAP:"
    refute out =~ "KILL_BEAM:"
    refute out =~ "LOCK_LEFT"
  end

  test "directory launch lock preserves a fresh ownerless acquisition window" do
    rel = fake_release()
    state = tmp_state()

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
    end)

    script = """
    aiur_resolve_identity
    lock=$(aiur_launch_lock_path)
    mkdir -p "$(dirname "$lock")"
    mkdir "$lock"
    sleep() { :; }
    set +e
    AIUR_LAUNCH_LOCK_TICKS=2 acquire_aiur_launch_lock "$lock"
    code=$?
    set -e
    echo "CODE=$code"
    [ -d "$lock" ] && echo LOCK_PRESERVED
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state}
      ])

    assert out =~ "CODE=1"
    assert out =~ "LOCK_PRESERVED"
  end

  test "bare foreground invocation preserves an existing session while its live node is not control-ready" do
    rel = fake_release()
    state = tmp_state()
    tmux_state = Aiur.TestSupport.tmp_root!("aiur-tmux-state")
    events = Aiur.TestSupport.tmp_root!("aiur-events")
    File.write!(tmux_state, "")
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *" new-session "*) echo "NEW_SESSION:$*" >> "#{events}"; exit 0 ;;
        *" attach "*) echo "ATTACH:$*" >> "#{events}"; exit 0 ;;
        *" kill-session "*) echo "KILL_SESSION:$*" >> "#{events}"; exit 0 ;;
        *" kill-server "*) echo "KILL_SERVER:$*" >> "#{events}"; exit 0 ;;
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
    probe_control_liveness() { printf down; }
    probe_node_liveness() { printf up; }
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
        {"EVENTS", events},
        {"PATH", path}
      ])

    assert out =~ "CODE=1"
    assert out =~ "control plane is not ready"
    refute out =~ "NEW_SESSION:"
    refute out =~ "ATTACH:"
    refute out =~ "KILL_SESSION:"
    refute out =~ "KILL_SERVER:"
    refute out =~ "REAP:"
    refute out =~ "KILL_BEAM:"
  end

  test "foreground attach filters tmux server-exited noise without process substitution" do
    rel = fake_release()
    state = tmp_state()
    tmux_state = Aiur.TestSupport.tmp_root!("aiur-tmux-state")
    events = Aiur.TestSupport.tmp_root!("aiur-events")
    dump = Aiur.TestSupport.tmp_root!("aiur-dump")
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*) touch "#{tmux_state}"; exit 0 ;;
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *" attach "*) echo "[server exited]" >&2; echo "real attach error" >&2; exit 7 ;;
        *" kill-session "*) rm -f "#{tmux_state}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(tmux_state)
      File.rm(events)
      File.rm(dump)
    end)

    script = """
    sleep() { :; }
    probe_control_liveness() { printf up; }
    start_beam_death_watchdog() {
      printf 'WATCHDOG' >> "$EVENTS"
      printf '<%s>' "$@" >> "$EVENTS"
      printf '\n' >> "$EVENTS"
      printf '424242\\n'
    }
    set +e
    ( run_session foreground --no-dashboard )
    code=$?
    set -e
    echo "CODE=$code"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"ERL_CRASH_DUMP", dump},
        {"EVENTS", events},
        {"PATH", path}
      ])

    assert out =~ "CODE=7"
    assert out =~ "Dashboard disabled by --no-dashboard."
    assert out =~ "real attach error"
    refute out =~ "[server exited]"

    assert File.read!(events) =~
             ~r/WATCHDOG<-name aiur-[^>]+><[^>]+><[^>]+><1><0><aiur-[^>]+><><><><[^>]+-workspace-root><[^>]+-alert-ledger><[^>]+-crash-dump-baseline>/
  end
end
