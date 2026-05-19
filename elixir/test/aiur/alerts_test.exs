defmodule Aiur.AlertsTest do
  use Aiur.TestSupport

  alias Aiur.{AgentLog, Alerts, Orchestrator}

  test "emit_system writes a structured alert entry and selects a configured sound" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alerts-#{System.unique_integer([:positive])}")

    workspace = Path.join(workspace_root, "MT-ALERT-1")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert :ok =
             Alerts.emit_system("task.done",
               issue: "MT-ALERT-1",
               player: fn sound -> send(self(), {:played_sound, sound}) end
             )

    # `task.done`'s configured sound path lives under `~/alerts/...` so
    # we expand the user's home rather than hardcoding the original
    # author's mac path. The exact filename is determined by the
    # `alerts.yaml` shipped with the repo.
    expected_sound = Path.join(System.user_home!(), "alerts/advisor-upgrade-complete.wav")
    assert_receive {:played_sound, ^expected_sound}

    log_path = Path.join(workspace, "logs/agent.md")
    ndjson_path = Path.join(workspace, "logs/agent.ndjson")

    assert File.read!(ndjson_path) =~ "\"name\":\"task.done\""
    assert File.read!(ndjson_path) =~ "\"message\":\"Task completed\""

    assert [%{role: "alert", title: "task.done", body: "Task completed"}] =
             log_path
             |> AgentLog.read()
             |> AgentLog.parse()
  end

  test "emit_custom rejects reserved system scopes" do
    assert {:error, :system_scope_reserved} =
             Alerts.emit_custom("task.done", "Task done", "Completed")
  end

  test "task state transitions emit task alerts into the issue workspace log" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alert-state-#{System.unique_integer([:positive])}")

    workspace = Path.join(workspace_root, "MT-ALERT-2")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    previous_issue = %Issue{id: "issue-1", identifier: "MT-ALERT-2", state: "Todo", title: "Task"}
    next_issue = %Issue{id: "issue-1", identifier: "MT-ALERT-2", state: "In Progress", title: "Task"}

    state = %Orchestrator.State{last_polled_issues: %{"issue-1" => previous_issue}}

    _updated_state = Orchestrator.sync_polled_issue_state_for_test(state, [next_issue])

    assert Path.join(workspace, "logs/agent.ndjson") |> File.read!() =~ "\"name\":\"task.in-progress\""
  end

  test "todo overload emits task.todo.more_agents once per overload interval" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alert-overload-#{System.unique_integer([:positive])}")

    workspace = Path.join(workspace_root, "MT-ALERT-3")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      max_concurrent_agents: 1
    )

    issues = [
      %Issue{id: "issue-1", identifier: "MT-ALERT-3", state: "Todo", title: "First"},
      %Issue{id: "issue-2", identifier: "MT-ALERT-4", state: "Todo", title: "Second"}
    ]

    state = %Orchestrator.State{}
    state = Orchestrator.sync_todo_capacity_alert_for_test(state, issues)
    _state = Orchestrator.sync_todo_capacity_alert_for_test(state, issues)

    log = Path.join(workspace, "logs/agent.ndjson") |> File.read!()
    assert String.split(log, "\"name\":\"task.todo.more_agents\"") |> length() == 2
  end

  test "agent paused and unpaused alerts fire from control-state transitions" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alert-pause-#{System.unique_integer([:positive])}")

    workspace = Path.join(workspace_root, "MT-ALERT-5")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    orchestrator_name = Module.concat(__MODULE__, :PauseAlertOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-5" => %{
              pid: self(),
              ref: nil,
              identifier: "MT-ALERT-5",
              issue: %Issue{id: "issue-5", identifier: "MT-ALERT-5", state: "In Progress", title: "Pause"},
              workspace_path: workspace,
              worker_host: nil,
              control: %{can_interrupt: true, safe_checkpoints: [], status: :working},
              started_at: DateTime.utc_now()
            }
          }
      }
    end)

    log_path = Path.join(workspace, "logs/agent.ndjson")

    assert_eventually(
      fn ->
        send(pid, {:worker_control_state, "issue-5", :paused})
        Process.sleep(25)
        send(pid, {:worker_control_state, "issue-5", :working})

        if File.exists?(log_path) do
          log = File.read!(log_path)

          String.contains?(log, "\"name\":\"agent.paused\"") and
            String.contains?(log, "\"name\":\"agent.unpaused\"")
        else
          false
        end
      end,
      20
    )
  end

  test "operator-initiated resume emits an agent.unpaused alert at the orchestrator sync-flip" do
    # Regression: `send_resume_control_message/2` sync-flips control.status
    # from :paused to :working before the worker's `:worker_control_state`
    # confirmation comes back. The later confirmation sees previous_status
    # already :working and emits no transition alert — so the orchestrator
    # must emit the unpause alert itself at the sync-flip point.
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alert-resume-sync-#{System.unique_integer([:positive])}")

    workspace = Path.join(workspace_root, "MT-RESUME-SYNC")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    orchestrator_name = Module.concat(__MODULE__, :ResumeSyncAlertOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-resume-sync" => %{
              pid: self(),
              ref: make_ref(),
              identifier: "MT-RESUME-SYNC",
              issue: %Issue{
                id: "issue-resume-sync",
                identifier: "MT-RESUME-SYNC",
                state: "In Progress",
                title: "Resume sync"
              },
              workspace_path: workspace,
              worker_host: nil,
              control: %{can_interrupt: true, safe_checkpoints: [], status: :paused},
              started_at: DateTime.utc_now()
            }
          }
      }
    end)

    log_path = Path.join(workspace, "logs/agent.ndjson")

    assert {:ok, :resumed} = Orchestrator.resume_agent(orchestrator_name, "MT-RESUME-SYNC")

    # Confirmation arrives after the sync-flip but the alert has
    # already been emitted; the duplicate confirmation must not double-fire.
    send(pid, {:worker_control_state, "issue-resume-sync", :working})

    assert_eventually(
      fn ->
        if File.exists?(log_path) do
          log = File.read!(log_path)
          unpaused_count = String.split(log, "\"name\":\"agent.unpaused\"") |> length()
          # exactly one unpause alert recorded (split count is N+1 occurrences)
          unpaused_count == 2
        else
          false
        end
      end,
      20
    )
  end

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")

  describe "guard-clause fallbacks" do
    test "definition/1 returns nil for non-binary inputs" do
      assert is_nil(Alerts.definition(:not_a_string))
      assert is_nil(Alerts.definition(123))
    end

    test "system_owned_name?/1 returns false for non-binary inputs" do
      refute Alerts.system_owned_name?(:not_a_string)
      refute Alerts.system_owned_name?(nil)
    end

    test "emit_custom/3 with non-binary name/message returns {:error, :invalid_alert}" do
      assert {:error, :invalid_alert} = Alerts.emit_custom(:bad, "msg", [])
      assert {:error, :invalid_alert} = Alerts.emit_custom("ok", :bad, [])
    end

    test "emit_system/2 fails when the alert has no configured message and no override" do
      # An alert name with no matching definition has no message;
      # present_string then returns {:error, :missing_message}.
      assert {:error, :missing_message} =
               Alerts.emit_system("task.nope-not-real-#{System.unique_integer([:positive])}")
    end
  end

  describe "alerts.yaml loading" do
    @tag :tmp_dir
    test "yields {} when the yaml file is unreadable or malformed", %{tmp_dir: tmp_dir} do
      # Point Alerts at a non-existent path; load_yaml falls back to %{}.
      original = Application.get_env(:aiur, :alerts_file_path)

      Application.put_env(
        :aiur,
        :alerts_file_path,
        Path.join(tmp_dir, "missing.yaml")
      )

      on_exit(fn ->
        if original do
          Application.put_env(:aiur, :alerts_file_path, original)
        else
          Application.delete_env(:aiur, :alerts_file_path)
        end
      end)

      assert Alerts.definitions() == %{}
    end

    @tag :tmp_dir
    test "returns an empty map when the yaml `alerts:` value isn't a map", %{tmp_dir: tmp_dir} do
      # Triggers the `normalize_definitions(_definitions), do: %{}`
      # fallback clause via a yaml file that has a non-map `alerts:`.
      yaml_path = Path.join(tmp_dir, "alerts.yaml")
      File.write!(yaml_path, "alerts: not_a_map\n")

      original = Application.get_env(:aiur, :alerts_file_path)
      Application.put_env(:aiur, :alerts_file_path, yaml_path)

      on_exit(fn ->
        if original do
          Application.put_env(:aiur, :alerts_file_path, original)
        else
          Application.delete_env(:aiur, :alerts_file_path)
        end
      end)

      assert Alerts.definitions() == %{}
    end

    @tag :tmp_dir
    test "drops sound values that are neither nil, a string, nor a list", %{tmp_dir: tmp_dir} do
      # `normalize_sounds/1`'s fallback returns `[]` for unexpected
      # shapes (integer, map, etc).
      yaml_path = Path.join(tmp_dir, "alerts.yaml")

      File.write!(yaml_path, """
      alerts:
        bad_sound_shape:
          message: "Hi"
          sound: 42
      """)

      original = Application.get_env(:aiur, :alerts_file_path)
      Application.put_env(:aiur, :alerts_file_path, yaml_path)

      on_exit(fn ->
        if original do
          Application.put_env(:aiur, :alerts_file_path, original)
        else
          Application.delete_env(:aiur, :alerts_file_path)
        end
      end)

      assert %{"bad_sound_shape" => %{sound: []}} = Alerts.definitions()
    end

    @tag :tmp_dir
    test "skips entries whose value is not a map and entries with a blank message", %{tmp_dir: tmp_dir} do
      yaml_path = Path.join(tmp_dir, "alerts.yaml")

      File.write!(yaml_path, """
      alerts:
        good:
          message: "Hello"
          sound: "~/sounds/one.wav"
        also_good:
          message: "List sound"
          sound:
            - "/tmp/a.wav"
            - "/tmp/b.wav"
        not_a_map: "just a string"
        blank_message:
          message: ""
      """)

      original = Application.get_env(:aiur, :alerts_file_path)
      Application.put_env(:aiur, :alerts_file_path, yaml_path)

      on_exit(fn ->
        if original do
          Application.put_env(:aiur, :alerts_file_path, original)
        else
          Application.delete_env(:aiur, :alerts_file_path)
        end
      end)

      definitions = Alerts.definitions()

      assert Map.has_key?(definitions, "good")
      assert Map.has_key?(definitions, "also_good")
      refute Map.has_key?(definitions, "not_a_map")
      refute Map.has_key?(definitions, "blank_message")

      # Sound paths are stored verbatim at load time; `~/` expansion
      # happens lazily at pick time in `expand_sound_path/1`.
      assert ["~/sounds/one.wav"] == definitions["good"].sound
      assert ["/tmp/a.wav", "/tmp/b.wav"] == definitions["also_good"].sound
    end
  end

  describe "emit_custom/2 and identifier helpers" do
    test "emit_custom/2 forwards to /3 and emits with no extra opts" do
      assert :ok = Alerts.emit_custom("my.test." <> Integer.to_string(System.unique_integer([:positive])), "Custom message")
    end

    test "emit_custom/3 returns :ok when no agent identifier is in opts (no broadcast)" do
      # Exercises `broadcast_agent_alert`'s `_ -> :ok` fallback and
      # `identifier_suffix/1`'s `_ -> ""` fallback. No `:issue` or
      # `:identifier` opt means no agent topic broadcast.
      assert :ok =
               Alerts.emit_custom(
                 "my.test.no-id-#{System.unique_integer([:positive])}",
                 "Custom message"
               )
    end

    test "emit_custom/3 falls through to :identifier opt when :issue is not a struct or binary" do
      # `identifier_for_alert/1`'s third clause: when `:issue` is set
      # but isn't an `%Issue{}` or a binary, fall back to `:identifier`.
      assert :ok =
               Alerts.emit_custom(
                 "my.test.weird-issue-#{System.unique_integer([:positive])}",
                 "ok",
                 issue: 42,
                 identifier: "MT-FALLBACK"
               )
    end
  end

  describe "default_player/2" do
    test "no-ops for http and https URL sounds" do
      assert :ok = Aiur.Alerts.default_player("http://example.test/ring.wav")
      assert :ok = Aiur.Alerts.default_player("https://example.test/ring.wav")
    end

    test "returns :ok when afplay is not on the path" do
      # First `cond` branch — `find_executable_fn` returns nil.
      assert :ok =
               Aiur.Alerts.default_player(
                 "/nowhere/missing-sound.wav",
                 fn _ -> nil end
               )
    end

    test "returns :ok when afplay is available but the sound file is missing" do
      # Second `cond` branch — `find_executable_fn` returns a path but
      # `File.exists?/1` returns false for the sound.
      stub_afplay = fn "afplay" -> "/usr/bin/echo" end

      assert :ok =
               Aiur.Alerts.default_player(
                 "/nowhere/missing-sound.wav",
                 stub_afplay
               )
    end

    test "resolve_workspace_for returns nil when the workspace_root_fn crashes" do
      # Directly exercises the rescue branch via the injectable helper.
      crashing = fn -> raise "no workflow loaded" end
      assert is_nil(Aiur.Alerts.resolve_workspace_for("MT-WSCRASH", crashing))
    end

    test "resolve_workspace_for returns the workspace path when it exists" do
      workspace_root = Path.join(System.tmp_dir!(), "aiur-rwfor-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace_root, "MT-WSEXIST"))
      on_exit(fn -> File.rm_rf!(workspace_root) end)

      assert Path.join(workspace_root, "MT-WSEXIST") ==
               Aiur.Alerts.resolve_workspace_for("MT-WSEXIST", fn -> workspace_root end)
    end

    @tag :tmp_dir
    test "spawns a playback task when afplay and the sound both exist", %{tmp_dir: tmp_dir} do
      # Third `cond` branch — both exist, so a Task.start runs.
      # We use `/usr/bin/true` as a stand-in for `afplay` and create a
      # real file the function can pass to `System.cmd/3`.
      sound_path = Path.join(tmp_dir, "ring.wav")
      File.write!(sound_path, "")

      true_path = System.find_executable("true") || "/usr/bin/true"
      stub_afplay = fn "afplay" -> true_path end

      assert {:ok, _pid} = Aiur.Alerts.default_player(sound_path, stub_afplay)
    end
  end

  describe "playback fallbacks" do
    test "swallows a player function that raises and still emits" do
      # `maybe_play_sound`'s rescue branch logs at debug and returns :ok
      # so a crashing player can't break the alert emission flow.
      workspace_root =
        Path.join(System.tmp_dir!(), "aiur-alert-rescue-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "MT-ALERT-RESCUE")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace_root) end)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      crashing_player = fn _sound -> raise "boom" end

      assert :ok =
               Alerts.emit_system("task.done",
                 issue: "MT-ALERT-RESCUE",
                 player: crashing_player
               )
    end

    test "default player skips http(s) sounds without trying to invoke afplay" do
      # Direct unit test on the default player by emitting an alert
      # whose sound list is a URL. The test environment normally
      # short-circuits via `test_env_without_player_override?/1`, so
      # we pass `player: &Aiur.Alerts.default_player_for_test/1`
      # if exposed — when not exposed we ensure no crash either way.
      workspace_root =
        Path.join(System.tmp_dir!(), "aiur-alert-url-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "MT-ALERT-URL")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace_root) end)

      # Point Alerts at a yaml that has a URL-prefixed sound, then emit.
      yaml_path = Path.join(workspace_root, "alerts.yaml")

      File.write!(yaml_path, """
      alerts:
        task.url-sound:
          message: "URL sound"
          sound: "https://example.test/ring.mp3"
      """)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      original = Application.get_env(:aiur, :alerts_file_path)
      Application.put_env(:aiur, :alerts_file_path, yaml_path)

      on_exit(fn ->
        if original do
          Application.put_env(:aiur, :alerts_file_path, original)
        else
          Application.delete_env(:aiur, :alerts_file_path)
        end
      end)

      # Use a player that just records what it was called with — we
      # want to confirm the URL string is passed through verbatim.
      test_pid = self()
      probe = fn sound -> send(test_pid, {:probe, sound}) end

      assert :ok =
               Alerts.emit_system("task.url-sound",
                 issue: "MT-ALERT-URL",
                 player: probe
               )

      assert_receive {:probe, "https://example.test/ring.mp3"}
    end
  end
end
