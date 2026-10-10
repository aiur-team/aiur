defmodule Aiur.Regression.EngineControlTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  describe "control-command identity isolation (#592)" do
    test "a control RPC from an unrelated cwd never adopts another instance's record" do
      rel = fake_release()
      state = tmp_state()
      base = Aiur.TestSupport.tmp_root!("aiur-control-iso")
      home = Path.join(base, "home")
      launch_root = Path.join(base, "project")
      other = Path.join(base, "other")
      events = Path.join(base, "events.log")
      File.mkdir_p!(home)
      File.mkdir_p!(launch_root)
      File.mkdir_p!(other)
      File.write!(events, "")

      File.write!(Path.join([rel, "bin", "aiur"]), """
      #!/usr/bin/env bash
      echo "NODE:$RELEASE_NODE" >> "$EVENTS"
      exit 42
      """)

      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(base)
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      script = """
      AIUR_BG_STATE_DIR="$STATE"
      AIUR_RELEASE_NODE=aiur-tester-live592@127.0.0.1
      AIUR_INSTANCE_KEY=live592
      AIUR_PROJECT_ROOT="$LAUNCH_ROOT"
      AIUR_PROJECT_ROOT_SOURCE=cwd
      write_aiur_instance_record aiur-tester-live592-default aiur-tester-live592

      cd "$OTHER"
      unset AIUR_RELEASE_NODE AIUR_INSTANCE_KEY AIUR_PROJECT_ROOT AIUR_PROJECT_ROOT_SOURCE
      AIUR_REPO_ROOT=
      probe_node_liveness() {
        case "$RELEASE_NODE" in
          "aiur-tester-live592@127.0.0.1") printf up ;;
          *) printf down ;;
        esac
      }
      if run_control_rpc "Aiur.AgentControlCLI.status()"; then
        CODE=0
      else
        CODE=$?
      fi
      echo "CODE=$CODE"
      """

      {out, 0} =
        run_sourced_engine(script, [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state},
          {"STATE", state},
          {"HOME", home},
          {"LAUNCH_ROOT", launch_root},
          {"OTHER", other},
          {"EVENTS", events},
          {"AIUR_RELEASE_NODE", nil},
          {"AIUR_INSTANCE_KEY", nil},
          {"AIUR_REPO_ROOT", nil}
        ])

      assert out =~ "CODE=1"
      assert out =~ "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry."
      assert out =~ "global-config control identity is keyed by cwd"
      assert out =~ "run control commands from the launch directory"
      assert out =~ "live launch directory candidate(s):"
      assert out =~ launch_root
      refute File.read!(events) =~ "live592"
    end
  end

  describe "reap scoping — never siblings, never the live run (#495/#498)" do
    @tag skip: Aiur.TestSupport.pgrep_skip_reason()
    test "kill_beams_matching reaps only the named node, sparing a sibling node-name" do
      marker_a = "aiur-reapa-#{System.unique_integer([:positive])}@127.0.0.1"
      marker_b = "aiur-reapb-#{System.unique_integer([:positive])}@127.0.0.1"
      state = tmp_state()
      on_exit(fn -> System.cmd("pkill", ["-f", marker_a], stderr_to_stdout: true) end)
      on_exit(fn -> System.cmd("pkill", ["-f", marker_b], stderr_to_stdout: true) end)
      on_exit(fn -> File.rm_rf(state) end)

      script = """
      source #{engine()}
      set +e
      bash -c 'exec -a "beam.smp -name #{marker_a} extra" sleep 10' >/dev/null 2>&1 &
      bash -c 'exec -a "beam.smp -name #{marker_b} extra" sleep 10' >/dev/null 2>&1 &
      seen=0
      for _ in $(seq 1 20); do
        pgrep_a="$(pgrep -f -- '#{marker_a}' 2>&1)"
        pgrep_a_status=$?
        pgrep_b="$(pgrep -f -- '#{marker_b}' 2>&1)"
        pgrep_b_status=$?
        case "$pgrep_a_status:$pgrep_b_status" in
          0:0) seen=1; break ;;
          0:1 | 1:0 | 1:1) ;;
          *)
            printf 'PGREP_ERROR: %s %s\\n' "$pgrep_a" "$pgrep_b"
            break
            ;;
        esac
        sleep 0.1
      done
      if [ "$seen" -ne 1 ]; then
        echo SETUP_FAILED
      else
        kill_beams_matching '-name #{marker_a}'
      fi
      pgrep_out="$(pgrep -f -- '#{marker_a}' 2>&1)"
      pgrep_status=$?
      case "$pgrep_status" in
        0) echo STILL_ALIVE ;;
        1)
          if [ -n "$pgrep_out" ]; then
            printf 'PGREP_ERROR: %s\\n' "$pgrep_out"
          else
            echo REAPED
          fi
          ;;
        *) printf 'PGREP_ERROR: %s\\n' "$pgrep_out" ;;
      esac
      pgrep_out="$(pgrep -f -- '#{marker_b}' 2>&1)"
      pgrep_status=$?
      case "$pgrep_status" in
        0) echo SIBLING_ALIVE ;;
        1)
          if [ -n "$pgrep_out" ]; then
            printf 'PGREP_ERROR: %s\\n' "$pgrep_out"
          else
            echo SIBLING_DEAD
          fi
          ;;
        *) printf 'PGREP_ERROR: %s\\n' "$pgrep_out" ;;
      esac
      """

      path = Aiur.TestSupport.tmp_root!("aiur-reap") <> ".sh"
      File.write!(path, script)
      on_exit(fn -> File.rm(path) end)

      {out, _} =
        System.cmd("bash", [path],
          env: [{"AIUR_RELEASE_NODE", nil}, {"AIUR_BG_STATE_DIR", state}],
          stderr_to_stdout: true
        )

      refute out =~ "PGREP_ERROR"
      refute out =~ "SETUP_FAILED"
      assert out =~ "REAPED"
      assert out =~ "SIBLING_ALIVE"
      refute out =~ "STILL_ALIVE"
      refute out =~ "SIBLING_DEAD"
    end

    test "reap_aiur_agents honors the pid-reuse comm guard and ignores pane lines" do
      tmp = Aiur.TestSupport.tmp_root!("aiur-agent-reap")
      live_dir = Path.join(tmp, "live")
      reused_dir = Path.join(tmp, "reused")
      File.mkdir_p!(live_dir)
      File.mkdir_p!(reused_dir)
      p1 = spawn_sleeper(live_dir)
      p2 = spawn_sleeper(reused_dir)
      pidfile = Path.join(tmp, "agents.pid")
      File.write!(pidfile, "pid #{p1} sleep\npid #{p2} beam.smp\npane %5\n")

      on_exit(fn ->
        kill_pid(p1)
        kill_pid(p2)
        File.rm_rf(tmp)
      end)

      {_, 0} = run_sourced_engine(~s|reap_aiur_agents "" "$PIDFILE"|, [{"PIDFILE", pidfile}])

      assert wait_dead(p1)
      assert os_pid_alive?(p2)
    end

    test "reap_aiur_agents is a no-op for a missing pidfile" do
      missing = "/nonexistent-pidfile-#{System.unique_integer([:positive])}"
      {out, 0} = run_sourced_engine(~s|reap_aiur_agents "" "#{missing}"; echo "CODE=$?"|, [])
      assert out =~ "CODE=0"
    end
  end

  describe "startup failure exits non-zero (#534)" do
    test "a background start whose control plane never becomes ready exits 1" do
      rel = fake_release()
      state = tmp_state()
      tmp = Aiur.TestSupport.tmp_root!("aiur-bg-never-ready")
      events = Path.join(tmp, "events.log")
      tmux_state = Path.join(tmp, "tmux-session")
      File.mkdir_p!(tmp)
      File.write!(events, "")

      tmux =
        fake_tmux_script("""
        case " $* " in
          *" new-session "*) touch "#{tmux_state}"; exit 0 ;;
          *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
          *" kill-session "*) rm -f "#{tmux_state}"; exit 0 ;;
          *) exit 0 ;;
        esac
        """)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
        File.rm_rf(tmp)
      end)

      script = """
      sleep() { :; }
      probe_control_liveness() { printf down; }
      reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
      kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
      preflight_stale_manual_smoke() { :; }
      set +e
      ( run_session background )
      code=$?
      set -e
      echo "CODE=$code"
      cat "$EVENTS"
      """

      {out, 0} =
        run_sourced_engine(script, [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state},
          {"AIUR_LOGS_ROOT", Path.join(tmp, "logs")},
          {"AIUR_NODE_GRACE_TICKS", "2"},
          {"EVENTS", events},
          {"HOME", tmp},
          {"PATH", "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"}
        ])

      assert out =~ "CODE=1"
      assert out =~ "was still booting"
      assert out =~ "KILL_BEAM:-name aiur-"
    end
  end

  describe "stale-session preflight (--bg idempotency)" do
    test "a live session with a responsive control plane is a no-op exit 0" do
      rel = fake_release()
      state = tmp_state()
      tmp = Aiur.TestSupport.tmp_root!("aiur-bg-live")
      events = Path.join(tmp, "events.log")
      File.mkdir_p!(tmp)
      File.write!(events, "")

      tmux =
        fake_tmux_script("""
        case " $* " in
          *" has-session "*) exit 0 ;;
          *" new-session "*) echo NEW_SESSION >> "#{events}"; exit 0 ;;
          *) exit 0 ;;
        esac
        """)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
        File.rm_rf(tmp)
      end)

      script = """
      sleep() { :; }
      probe_control_liveness() { printf up; }
      preflight_stale_manual_smoke() { :; }
      run_session background
      echo "CODE=$?"
      test -f "$(aiur_instance_record_path)" && echo RECORD_OK
      """

      {out, 0} =
        run_sourced_engine(script, [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state},
          {"AIUR_LOGS_ROOT", Path.join(tmp, "logs")},
          {"HOME", tmp},
          {"PATH", "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"}
        ])

      assert out =~ "CODE=0"
      assert out =~ "already running in the background"
      assert out =~ "Attach with: aiur"
      refute out =~ "Config:"
      assert out =~ "RECORD_OK"
      refute File.read!(events) =~ "NEW_SESSION"
      refute File.exists?(Path.join(tmp, "logs"))
    end

    test "a session that becomes responsive during stale confirmation is preserved" do
      rel = fake_release()
      state = tmp_state()
      tmp = Aiur.TestSupport.tmp_root!("aiur-bg-race")
      events = Path.join(tmp, "events.log")
      counter = Path.join(tmp, "control-probes")
      File.mkdir_p!(tmp)
      File.write!(events, "")

      tmux =
        fake_tmux_script("""
        case " $* " in
          *" has-session "*) exit 0 ;;
          *" new-session "*) echo NEW_SESSION >> "#{events}"; exit 0 ;;
          *) exit 0 ;;
        esac
        """)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
        File.rm_rf(tmp)
      end)

      script = """
      sleep() { :; }
      probe_control_liveness() {
        count=$(cat "$COUNTER" 2>/dev/null || printf 0)
        count=$((count + 1))
        printf '%s' "$count" > "$COUNTER"
        if [ "$count" -eq 1 ]; then printf down; else printf up; fi
      }
      probe_node_liveness() { printf down; }
      reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
      kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
      set +e
      run_session background
      code=$?
      set -e
      echo "CODE=$code"
      """

      {out, 0} =
        run_sourced_engine(script, [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state},
          {"COUNTER", counter},
          {"EVENTS", events},
          {"HOME", tmp},
          {"PATH", "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"}
        ])

      assert out =~ "CODE=1"
      assert out =~ "became live while checking stale state"
      refute File.read!(events) =~ "REAP:"
      refute File.read!(events) =~ "KILL_BEAM:"
      refute File.read!(events) =~ "NEW_SESSION"
    end

    test "a stale session (control plane down) is reaped before relaunch" do
      rel = fake_release()
      state = tmp_state()
      tmp = Aiur.TestSupport.tmp_root!("aiur-bg-stale")
      events = Path.join(tmp, "events.log")
      tmux_state = Path.join(tmp, "tmux-session")
      reaped = Path.join(tmp, "reaped")
      File.mkdir_p!(tmp)
      File.write!(events, "")
      File.write!(tmux_state, "")

      tmux =
        fake_tmux_script("""
        case " $* " in
          *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
          *" new-session "*) echo NEW_SESSION >> "#{events}"; touch "#{tmux_state}"; exit 0 ;;
          *) exit 0 ;;
        esac
        """)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
        File.rm_rf(tmp)
      end)

      script = """
      sleep() { :; }
      probe_control_liveness() {
        if [ -f "$REAPED" ]; then printf up; else printf down; fi
      }
      probe_node_liveness() { printf down; }
      reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; touch "$REAPED"; rm -f "$TMUX_STATE"; }
      kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
      start_beam_death_watchdog() { printf '424242\\n'; }
      disown() { :; }
      preflight_stale_manual_smoke() { :; }
      run_session background
      echo "CODE=$?"
      """

      {out, 0} =
        run_sourced_engine(script, [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state},
          {"XDG_RUNTIME_DIR", state},
          {"AIUR_LOGS_ROOT", Path.join(tmp, "logs")},
          {"AIUR_NODE_GRACE_TICKS", "2"},
          {"EVENTS", events},
          {"HOME", tmp},
          {"REAPED", reaped},
          {"TMUX_STATE", tmux_state},
          {"PATH", "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"}
        ])

      events_log = File.read!(events)
      assert out =~ "CODE=0"
      assert out =~ "found stale tmux session"
      assert events_log =~ "REAP:"
      assert events_log =~ "NEW_SESSION"
      assert :binary.match(events_log, "REAP:") < :binary.match(events_log, "NEW_SESSION")
    end
  end
end
