defmodule Aiur.Regression.EngineControlTest do
  use ExUnit.Case, async: true

  @engine Path.expand("../../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)
  @pgrep_skip_reason Aiur.TestSupport.pgrep_skip_reason()

  describe "control-command identity isolation (#592)" do
    test "a control RPC from an unrelated cwd never adopts another instance's record" do
      rel = fake_release()
      state = tmp_state()
      base = Path.join(System.tmp_dir!(), "aiur-control-iso-#{System.unique_integer([:positive])}")
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
      assert out =~ "no running aiur node at aiur-"
      assert out =~ "global-config control identity is keyed by cwd #{realpath(other)}"
      assert out =~ "run control commands from the launch directory"
      refute File.read!(events) =~ "live592"
    end
  end

  describe "reap scoping — never siblings, never the live run (#495/#498)" do
    @tag skip: @pgrep_skip_reason
    test "kill_beams_matching reaps only the named node, sparing a sibling node-name" do
      marker_a = "aiur-reapa-#{System.unique_integer([:positive])}@127.0.0.1"
      marker_b = "aiur-reapb-#{System.unique_integer([:positive])}@127.0.0.1"
      state = tmp_state()
      on_exit(fn -> System.cmd("pkill", ["-f", marker_a], stderr_to_stdout: true) end)
      on_exit(fn -> System.cmd("pkill", ["-f", marker_b], stderr_to_stdout: true) end)
      on_exit(fn -> File.rm_rf(state) end)

      script = """
      source #{@engine}
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

      path = Path.join(System.tmp_dir!(), "aiur-reap-#{System.unique_integer([:positive])}.sh")
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
      tmp = Path.join(System.tmp_dir!(), "aiur-agent-reap-#{System.unique_integer([:positive])}")
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

  describe "control RPC exit-marker protocol (FI-CLI-029)" do
    test "a zero marker yields exit 0 and :ok/blank noise lines are filtered" do
      rel = fake_release()
      state = tmp_state()

      File.write!(Path.join([rel, "bin", "aiur"]), """
      #!/usr/bin/env bash
      echo ":ok"
      echo ""
      echo "row1"
      echo "__AIUR_CONTROL_EXIT__:0"
      """)

      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_sourced_engine(
          ~s|if run_control_rpc "Aiur.AgentControlCLI.status()"; then code=0; else code=$?; fi; echo "CODE=$code"|,
          [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}]
        )

      assert out =~ "CODE=0"
      assert out =~ "row1"
      refute out =~ ":ok"
    end

    test "a nonzero marker propagates as the exit code" do
      rel = fake_release()
      state = tmp_state()
      File.write!(Path.join([rel, "bin", "aiur"]), "#!/usr/bin/env bash\necho \"__AIUR_CONTROL_EXIT__:1\"\n")
      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_sourced_engine(
          ~s|if run_control_rpc "Aiur.AgentControlCLI.status()"; then code=0; else code=$?; fi; echo "CODE=$code"|,
          [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}]
        )

      assert out =~ "CODE=1"
      refute out =~ "returned no exit marker"
      refute out =~ "no running aiur node"
    end

    test "a missing marker is an error" do
      rel = fake_release()
      state = tmp_state()
      File.write!(Path.join([rel, "bin", "aiur"]), "#!/usr/bin/env bash\necho hello\n")
      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_sourced_engine(
          ~s|if run_control_rpc "Aiur.AgentControlCLI.status()"; then code=0; else code=$?; fi; echo "CODE=$code"|,
          [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}]
        )

      assert out =~ "CODE=1"
      assert out =~ "returned no exit marker"
    end

    test "a hung rpc is killed and surfaces exit 124" do
      rel = fake_release()
      state = tmp_state()
      File.write!(Path.join([rel, "bin", "aiur"]), "#!/usr/bin/env bash\nsleep 5\n")
      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_sourced_engine(
          ~s|if run_control_rpc "Aiur.AgentControlCLI.status()"; then code=0; else code=$?; fi; echo "CODE=$code"|,
          [
            {"AIUR_RELEASE_DIR", rel},
            {"AIUR_BG_STATE_DIR", state},
            {"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", "1"}
          ]
        )

      assert out =~ "CODE=124"
      assert out =~ "timed out after 1s"
    end

    test "the marker and readiness literals are pinned across both languages" do
      cli = File.read!(Path.expand("../../../lib/aiur/agent_control_cli.ex", __DIR__))
      engine = File.read!(@engine)

      assert cli =~ ~s|@exit_marker "__AIUR_CONTROL_EXIT__:"|
      assert engine =~ ~s|marker="__AIUR_CONTROL_EXIT__:"|
      assert engine =~ "__AIUR_CONTROL_READY__"
      assert engine =~ "__AIUR_CONTROL_NOT_READY__"
    end
  end

  describe "startup failure exits non-zero (#534)" do
    test "a background start whose control plane never becomes ready exits 1" do
      rel = fake_release()
      state = tmp_state()
      tmp = Path.join(System.tmp_dir!(), "aiur-bg-never-ready-#{System.unique_integer([:positive])}")
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
      assert out =~ "aiur control plane did not become ready"
      assert out =~ "KILL_BEAM:-name aiur-"
    end
  end

  describe "stale-session preflight (--bg idempotency)" do
    test "a live session with a responsive control plane is a no-op exit 0" do
      rel = fake_release()
      state = tmp_state()
      tmp = Path.join(System.tmp_dir!(), "aiur-bg-live-#{System.unique_integer([:positive])}")
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
      assert out =~ "RECORD_OK"
      refute File.read!(events) =~ "NEW_SESSION"
    end

    test "a stale session (control plane down) is reaped before relaunch" do
      rel = fake_release()
      state = tmp_state()
      tmp = Path.join(System.tmp_dir!(), "aiur-bg-stale-#{System.unique_integer([:positive])}")
      events = Path.join(tmp, "events.log")
      tmux_state = Path.join(tmp, "tmux-session")
      counter = Path.join(tmp, "counter")
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
        if [ ! -f "$COUNTER" ]; then
          echo 1 > "$COUNTER"
          printf down
        else
          printf up
        fi
      }
      reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; rm -f "$TMUX_STATE"; }
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
          {"AIUR_LOGS_ROOT", Path.join(tmp, "logs")},
          {"AIUR_NODE_GRACE_TICKS", "2"},
          {"COUNTER", counter},
          {"EVENTS", events},
          {"HOME", tmp},
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

  # A minimal stub release: start_erl.data + a fake `elixir` that echoes its args
  # so dispatch/boot-shape can be asserted without a real BEAM.
  defp fake_release do
    dir = Path.join(System.tmp_dir!(), "aiur-engine-rel-#{System.unique_integer([:positive])}")
    vsn = Path.join([dir, "releases", "0.1.1"])
    File.mkdir_p!(vsn)
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join([dir, "releases", "start_erl.data"]), "16.4 0.1.1\n")
    elixir = Path.join(vsn, "elixir")
    File.write!(elixir, "#!/usr/bin/env bash\necho \"ELIXIR_ARGS: $*\"\n")
    File.chmod!(elixir, 0o755)
    for f <- ["sys", "start_clean", "vm.args"], do: File.write!(Path.join(vsn, f), "")
    File.write!(Path.join([dir, "bin", "aiur"]), "#!/usr/bin/env bash\necho \"BIN: $*\"\n")
    File.chmod!(Path.join([dir, "bin", "aiur"]), 0o755)
    dir
  end

  defp tmp_state, do: Path.join(System.tmp_dir!(), "aiur-st-#{System.unique_integer([:positive])}")

  defp realpath(path) do
    {out, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(out)
  end

  defp spawn_sleeper(cwd) do
    port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "exec sleep 300"], cd: cwd])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid
  end

  defp os_pid_alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))

  defp wait_dead(pid, attempts \\ 50)
  defp wait_dead(pid, 0), do: not os_pid_alive?(pid)

  defp wait_dead(pid, attempts) do
    if os_pid_alive?(pid) do
      Process.sleep(50)
      wait_dead(pid, attempts - 1)
    else
      true
    end
  end

  defp kill_pid(pid), do: System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

  defp run_sourced_engine(script, env) do
    # The engine's launch/stop paths reap any BEAM holding their node name
    # (`kill_beams_matching "-name $AIUR_RELEASE_NODE"`). Sourced from `mix test`
    # on a host running a live aiur, an un-isolated run resolves the SAME node
    # name and reaps the operator's BEAM. Pin a unique, non-existent node unless
    # the caller set one, so these reaps can never match a real process.
    env =
      if List.keymember?(env, "AIUR_RELEASE_NODE", 0) do
        env
      else
        [{"AIUR_RELEASE_NODE", "aiur-engctl-#{System.unique_integer([:positive])}@127.0.0.1"} | env]
      end

    System.cmd("bash", ["-c", "set -euo pipefail\nsource \"$AIUR_ENGINE\"\n#{script}"],
      env: [{"AIUR_ENGINE", @engine} | env],
      stderr_to_stdout: true
    )
  end

  defp fake_tmux_script(body) do
    dir = Path.join(System.tmp_dir!(), "aiur-fake-tmux-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "tmux")
    File.write!(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end
end
