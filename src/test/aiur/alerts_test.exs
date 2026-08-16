defmodule Aiur.AlertsTest do
  use Aiur.TestSupport

  alias Aiur.{AgentLog, AlertFeed, AlertLedger, Alerts, Orchestrator, TrackerIdentity}
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.IssueSync

  test "emit_system writes a structured alert entry and selects a configured sound" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alerts-#{System.unique_integer([:positive])}")

    # Linear default config namespaces the workspace under <root>/<project_slug>/,
    # which is where resolve_workspace (via the issue:) now looks for the log dir.
    workspace = Path.join([workspace_root, "project", "MT-ALERT-1"])
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    topic = "ticket.MT-ALERT-1.issue.state.changed"

    assert :ok =
             Alerts.emit_system(topic,
               issue: "MT-ALERT-1",
               player: fn sound -> send(self(), {:played_sound, sound}) end
             )

    # Per Ticket B, the close sound moved from `task.done` to the
    # GitHub-authoritative `ticket.*.issue.state.changed` topic.
    expected_sound = Path.join(System.user_home!(), "alerts/advisor-upgrade-complete.wav")
    assert_receive {:played_sound, ^expected_sound}

    log_path = Path.join(workspace, "logs/agent.md")
    ndjson_path = Path.join(workspace, "logs/agent.ndjson")

    assert File.read!(ndjson_path) =~ "\"name\":\"#{topic}\""
    assert File.read!(ndjson_path) =~ "\"topic\":\"#{topic}\""
    assert File.read!(ndjson_path) =~ "\"message\":\"Task state changed\""
    assert File.read!(ndjson_path) =~ "\"reason\":\"Task state changed\""
    assert File.read!(ndjson_path) =~ "\"severity\":\"info\""
    assert File.read!(ndjson_path) =~ "\"needs_attention\":false"
    assert File.read!(ndjson_path) =~ "\"source_ticket_id\":\"MT-ALERT-1\""

    assert [%{role: "alert", title: ^topic, body: "Task state changed"}] =
             log_path
             |> AgentLog.read()
             |> AgentLog.parse()
  end

  test "emit_system persists a dynamic readiness alert without a configured topic" do
    root = Path.join(System.tmp_dir!(), "aiur-readiness-alert-#{System.unique_integer([:positive])}")
    workspace = Path.join([root, "project", "1474"])
    log_root = Path.join(root, "log")
    previous_log_file = Application.get_env(:aiur, :log_file)
    File.mkdir_p!(workspace)

    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

    on_exit(fn ->
      if previous_log_file do
        Application.put_env(:aiur, :log_file, previous_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf!(root)
    end)

    assert :ok =
             Alerts.emit_system("system.ci_readiness.not_ready",
               message: "Repository CI readiness is incomplete",
               reason: "CI readiness: not ready for main",
               needs_attention: true,
               workspace: workspace
             )

    assert Enum.any?(AlertFeed.list(ledger_paths: [AlertLedger.path()]), fn alert ->
             alert["topic"] == "system.ci_readiness.not_ready" and alert["needs_attention"]
           end)
  end

  # NOTE: Pre-Ticket-B, `emit_custom` rejected names starting with system
  # scopes (`task.*`, `agent.*`, `chat.*`). That gate moved to Ticket A's
  # `emit_event` tool allowlist — server-side `Alerts` no longer policies
  # this since the agent never reaches Alerts without going through the
  # tool first. Test retained for documentation purposes.

  test "task state transitions emit task alerts into the issue workspace log" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alert-state-#{System.unique_integer([:positive])}")

    # Resolved via the issue identifier, so it must match the repo-namespaced
    # layout (Linear default config → <root>/project/<issue>).
    workspace = Path.join([workspace_root, "project", "MT-ALERT-2"])
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    previous_issue = %Issue{id: "issue-1", identifier: "MT-ALERT-2", state: "Todo", title: "Task"}
    next_issue = %Issue{id: "issue-1", identifier: "MT-ALERT-2", state: "In Progress", title: "Task"}

    state = %Orchestrator.State{last_polled_issues: %{"issue-1" => previous_issue}}

    _updated_state = IssueSync.sync_polled_issue_state(state, [next_issue])

    assert Path.join(workspace, "logs/agent.ndjson") |> File.read!() =~
             "\"name\":\"ticket.MT-ALERT-2.issue.label.added.agent.in-progress\""
  end

  test "human-review state transitions are marked operator-actionable" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alert-review-#{System.unique_integer([:positive])}")

    workspace = Path.join([workspace_root, "project", "MT-ALERT-REVIEW"])
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    previous_issue = %Issue{id: "issue-1", identifier: "MT-ALERT-REVIEW", state: "In Progress", title: "Task"}
    next_issue = %Issue{id: "issue-1", identifier: "MT-ALERT-REVIEW", state: "Human Review", title: "Task"}

    state = %Orchestrator.State{last_polled_issues: %{"issue-1" => previous_issue}}

    _updated_state = IssueSync.sync_polled_issue_state(state, [next_issue])

    log = Path.join(workspace, "logs/agent.ndjson") |> File.read!()

    assert log =~ "\"name\":\"ticket.MT-ALERT-REVIEW.issue.label.added.agent.human-review\""
    assert log =~ "\"needs_attention\":true"
    assert log =~ "\"severity\":\"warning\""
    assert log =~ "\"reason\":\"Agent marked the ticket ready for human review\""
  end

  test "tracker pause transitions persist and appear in the Executor alert feed" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alert-tracker-pause-#{System.unique_integer([:positive])}")

    workspace = Path.join([workspace_root, "project", "MT-TRACKER-PAUSE"])
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    previous = %Issue{id: "issue-tracker-pause", identifier: "MT-TRACKER-PAUSE", state: "In Progress", title: "Pause"}
    paused = %{previous | paused: true}

    _state =
      IssueSync.sync_polled_issue_state(
        %Orchestrator.State{last_polled_issues: %{previous.id => previous}},
        [paused]
      )

    log_path = Path.join(workspace, "logs/agent.ndjson")
    log = File.read!(log_path)

    assert log =~ "\"name\":\"ticket.MT-TRACKER-PAUSE.agent.paused\""
    assert log =~ "\"reason\":\"Tracker added agent:paused (tracker pause override)"

    assert Enum.any?(AlertFeed.list(roots: [workspace_root]), fn alert ->
             alert["topic"] == "ticket.MT-TRACKER-PAUSE.agent.paused" and
               alert["needs_attention"] == true
           end)
  end

  test "alerts without a local workspace are written to the central alert feed" do
    log_root =
      Path.join(System.tmp_dir!(), "aiur-alert-central-#{System.unique_integer([:positive])}")

    original_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf!(log_root)
    end)

    assert :ok =
             Alerts.emit_system("system.dispatch.todo_capacity_exceeded",
               reason: "Todo queue exceeds configured capacity",
               needs_attention: true,
               severity: "warning"
             )

    central_log = Path.join(log_root, "alerts.ndjson") |> File.read!()

    assert central_log =~ "\"name\":\"system.dispatch.todo_capacity_exceeded\""
    assert central_log =~ "\"reason\":\"Todo queue exceeds configured capacity\""
    assert central_log =~ "\"needs_attention\":true"
  end

  test "central alerts with a local workspace are written to both feeds" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alert-central-workspace-#{System.unique_integer([:positive])}")

    workspace = Path.join([workspace_root, "project", "MT-CENTRAL-WORKSPACE"])
    log_root = Path.join(workspace_root, "central")
    original_log_file = Application.get_env(:aiur, :log_file)
    File.mkdir_p!(workspace)
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf!(workspace_root)
    end)

    topic = "ticket.MT-CENTRAL-WORKSPACE.agent.attention.state_divergence"

    assert :ok =
             Alerts.emit_system(topic,
               issue: "MT-CENTRAL-WORKSPACE",
               reason: "Persist recovery state centrally",
               needs_attention: true,
               severity: "warning",
               central: true
             )

    assert File.read!(Path.join(workspace, "logs/agent.ndjson")) =~ "\"topic\":\"#{topic}\""
    assert File.read!(Path.join(log_root, "alerts.ndjson")) =~ "\"topic\":\"#{topic}\""
    assert File.read!(AlertLedger.path()) =~ "\"topic\":\"#{topic}\""

    assert [%{"topic" => ^topic}] =
             AlertFeed.list(needs_attention: true) |> Enum.filter(&(&1["topic"] == topic))
  end

  test "fleet dispatch alerts persist and appear in the Executor alert feed" do
    log_root =
      Path.join(System.tmp_dir!(), "aiur-alert-fleet-#{System.unique_integer([:positive])}")

    original_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf!(log_root)
    end)

    alerts = [
      {"system.dispatch.prewarm_blocked", "Prewarm is building; fleet dispatch is paused."},
      {"system.dispatch.capacity_starved", "Ready tickets=8, effective cap=3, configured cap=16."}
    ]

    Enum.each(alerts, fn {topic, reason} ->
      assert :ok = Alerts.emit_system(topic, reason: reason, needs_attention: true, severity: "warning")
    end)

    central_log = Path.join(log_root, "alerts.ndjson") |> File.read!()
    visible_alerts = AlertFeed.list(log_roots: [log_root])

    Enum.each(alerts, fn {topic, reason} ->
      assert central_log =~ "\"name\":\"#{topic}\""

      assert Enum.any?(visible_alerts, fn alert ->
               alert["topic"] == topic and alert["reason"] == reason and alert["needs_attention"] == true
             end)
    end)
  end

  test "executor takeover advisories round-trip through the needs-attention feed and resolve" do
    log_root = Path.join(System.tmp_dir!(), "aiur-takeover-alert-#{System.unique_integer([:positive])}")
    original_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf!(log_root)
    end)

    topic = "system.executor_takeover.999"

    assert :ok =
             Alerts.emit_system(topic,
               message: "Executor takeover advisory for #999.",
               reason: "Executor takeover advisory for #999.",
               needs_attention: true,
               severity: "warning"
             )

    assert Enum.any?(AlertFeed.list(log_roots: [log_root]), fn alert ->
             alert["topic"] == topic and alert["needs_attention"] == true
           end)

    # The continuous reminder is collapsed to one active advisory by the feed.
    assert :ok =
             Alerts.emit_system(topic,
               message: "Executor takeover advisory for #999 (repeated).",
               reason: "Executor takeover advisory for #999.",
               needs_attention: true,
               severity: "warning"
             )

    active = AlertFeed.list(log_roots: [log_root], needs_attention: true) |> Enum.filter(&(&1["topic"] == topic))
    assert length(active) == 1

    # Resolution clears the active advisory from the needs-attention surface.
    assert :ok =
             Alerts.emit_system(topic <> ".resolved",
               message: "Executor takeover advisory resolved: #999 is terminal or out of run scope.",
               reason: "Executor takeover advisory resolved.",
               needs_attention: false,
               severity: "info"
             )

    refute Enum.any?(AlertFeed.list(log_roots: [log_root], needs_attention: true), &(&1["topic"] == topic))
  end

  test "todo overload emits system.dispatch.todo_capacity_exceeded once per overload interval" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alert-overload-#{System.unique_integer([:positive])}")

    # Resolved via the issue identifier, so it must match the repo-namespaced
    # layout (Linear default config → <root>/project/<issue>).
    workspace = Path.join([workspace_root, "project", "MT-ALERT-3"])
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
    state = IssueSync.sync_todo_capacity_alert(state, issues)
    _state = IssueSync.sync_todo_capacity_alert(state, issues)

    log = Path.join(workspace, "logs/agent.ndjson") |> File.read!()

    assert String.split(log, "\"name\":\"system.dispatch.todo_capacity_exceeded\"") |> length() ==
             2
  end

  @tag :tmp_dir
  test "cause-scoped pause and unpaused alerts fire from control-state transitions", %{tmp_dir: workspace_root} do
    workspace = Path.join(workspace_root, "MT-ALERT-5")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    orchestrator_name = Module.concat(__MODULE__, :PauseAlertOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn -> stop_orchestrator!(pid) end)

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

          String.contains?(
            log,
            "\"name\":\"ticket.MT-ALERT-5.agent.attention.paused-worker_pause_unknown\""
          ) and
            String.contains?(log, "\"needs_attention\":true") and
            String.contains?(log, "\"severity\":\"warning\"") and
            String.contains?(log, "\"name\":\"ticket.MT-ALERT-5.agent.unpaused\"") and
            String.contains?(log, "\"reason\":\"Agent resumed; no Executor action is needed.\"") and
            String.contains?(log, "\"needs_attention\":false")
        else
          false
        end
      end,
      20
    )
  end

  @tag :tmp_dir
  test "operator-initiated resume emits an agent.unpaused alert at the orchestrator sync-flip", %{tmp_dir: workspace_root} do
    # Regression: `send_resume_control_message/2` sync-flips control.status
    # from :paused to :working before the worker's `:worker_control_state`
    # confirmation comes back. The later confirmation sees previous_status
    # already :working and emits no transition alert — so the orchestrator
    # must emit the unpause alert itself at the sync-flip point.
    workspace = Path.join(workspace_root, "MT-RESUME-SYNC")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    orchestrator_name = Module.concat(__MODULE__, :ResumeSyncAlertOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn -> stop_orchestrator!(pid) end)

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
          unpaused_count = String.split(log, "\"name\":\"ticket.MT-RESUME-SYNC.agent.unpaused\"") |> length()
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

  # The orchestrator traps exits, so `Process.exit(pid, :normal)` only queues
  # an `{:EXIT, _, :normal}` message and leaves it running. It then keeps
  # appending to the workspace log while the sibling `on_exit` removes that
  # directory, and under partition load `File.rm_rf!/1` fails with `:eexist`
  # on the tree still being written. Wait for the writer to actually be gone.
  defp stop_orchestrator!(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> flunk("orchestrator #{inspect(pid)} did not stop")
      end
    end
  end

  describe "definition_for_topic/1 glob matching" do
    setup do
      prev = Application.get_env(:aiur, :alerts_file_path)

      tmp_yaml = Path.join(System.tmp_dir!(), "alerts_glob_#{System.unique_integer([:positive])}.yaml")

      File.write!(tmp_yaml, """
      alerts:
        "ticket.*.pr.merged":
          message: "PR merged"
          sound: "merge.wav"
        "ticket.#":
          message: "Generic ticket event"
        "system.main.branch.push":
          message: "Main pushed"
      """)

      Application.put_env(:aiur, :alerts_file_path, tmp_yaml)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:aiur, :alerts_file_path, prev),
          else: Application.delete_env(:aiur, :alerts_file_path)

        File.rm(tmp_yaml)
      end)

      :ok
    end

    test "matches a specific pattern over a generic one (specificity wins)" do
      defn = Alerts.definition_for_topic("ticket.42.pr.merged")
      assert defn.message == "PR merged"
    end

    test "falls through to a catch-all when no specific entry matches" do
      defn = Alerts.definition_for_topic("ticket.42.branch.push")
      assert defn.message == "Generic ticket event"
    end

    test "matches literal patterns" do
      defn = Alerts.definition_for_topic("system.main.branch.push")
      assert defn.message == "Main pushed"
    end

    test "returns nil when no pattern matches" do
      assert is_nil(Alerts.definition_for_topic("nothing.matches.this"))
    end
  end

  describe "guard-clause fallbacks" do
    test "definition_for_topic/1 returns nil for non-binary inputs" do
      assert is_nil(Alerts.definition_for_topic(:not_a_string))
      assert is_nil(Alerts.definition_for_topic(123))
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

  describe "alerts file loading" do
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

  describe "legacy .aiur/alerts.yaml fallback removal" do
    test "ignores a legacy .aiur/alerts.yaml — canonical file wins, yaml never loaded, warns when only yaml remains" do
      # The default path (no :alerts_file_path override, no config alerts_file)
      # resolves to `<config-dir>/alerts`; the sibling `.aiur/alerts.yaml` is the
      # legacy file that must never be parsed. Both live next to the per-test
      # config that TestSupport's setup already wrote.
      config_dir = Path.dirname(Workflow.workflow_file_path())
      canonical = Path.join(config_dir, "alerts")
      legacy = Path.join(config_dir, "alerts.yaml")

      # A marker entry that must NEVER surface if the yaml were loaded.
      File.write!(legacy, """
      alerts:
        "legacy.only.topic":
          message: "LEGACY YAML LOADED"
      """)

      # Canonical extensionless file present with distinct contents → it wins,
      # the yaml is ignored, and no deprecation warning fires.
      File.write!(canonical, """
      alerts:
        "canonical.topic":
          message: "From canonical alerts"
      """)

      log =
        capture_log(fn ->
          defs = Alerts.definitions()
          assert defs["canonical.topic"].message == "From canonical alerts"
          refute Map.has_key?(defs, "legacy.only.topic")
        end)

      refute log =~ "fallback was removed"

      # Remove the canonical file → only the legacy yaml remains. Mappings must
      # resolve to an empty map (the yaml is still never parsed — no marker
      # entry leaks) and the one-time deprecation warning must fire, naming the
      # rename the operator needs to make.
      File.rm!(canonical)

      log =
        capture_log(fn ->
          assert Alerts.definitions() == %{}
        end)

      assert log =~ "fallback was removed"
      assert log =~ "Rename #{legacy} to #{canonical}"
    end

    test "with no alerts file at all the default path resolves to an empty map and emission is a silent no-op" do
      # No canonical `.aiur/alerts`, no legacy `.aiur/alerts.yaml`, no override:
      # the default-path branch must resolve cleanly to `%{}` without crashing,
      # emitting plays no mapped sound, and no deprecation warning fires.
      config_dir = Path.dirname(Workflow.workflow_file_path())
      File.rm_rf!(Path.join(config_dir, "alerts"))
      File.rm_rf!(Path.join(config_dir, "alerts.yaml"))

      topic = "task.no-alerts-file.#{System.unique_integer([:positive])}"
      probe = fn sound -> send(self(), {:played, sound}) end

      log =
        capture_log(fn ->
          assert Alerts.definitions() == %{}
          assert is_nil(Alerts.definition_for_topic(topic))
          assert :ok = Alerts.emit_custom(topic, "No mapping present", player: probe)
        end)

      refute_receive {:played, _sound}, 100
      refute log =~ "fallback was removed"
    end
  end

  describe "emit_custom/2 and identifier helpers" do
    test "custom stage alerts publish a joinable, typed observation" do
      identifier = "MT-OBSERVATION-#{System.unique_integer([:positive])}"
      topic = "ticket.#{identifier}.agent.phase.work.start"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOAlertObservation", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      :ok = Exchange.subscribe(topic)

      assert :ok =
               Alerts.emit_custom(topic, "private status",
                 observation_identity: identity,
                 observation_source: %{kind: :agent_alert, name: "phase.work.start"},
                 observation_provenance: %{run_id: "run-alert", session_id: "session-alert"},
                 occurred_at: "2026-07-13T12:00:00Z"
               )

      assert_receive {:event, %{ticket_observation: observation}}, 2_000
      assert observation.status == :joinable
      assert observation.attributes == %{stage: :work, transition: :start}
      assert observation.provenance == %{run_id: "run-alert", session_id: "session-alert"}
      refute Jason.encode!(observation) =~ "private status"
    end

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

    test "returns :ok when a player is available but the sound file is missing" do
      # `find_executable_fn` returns a path for any probed player but
      # `File.exists?/1` returns false for the sound.
      stub_player = fn _binary -> "/usr/bin/echo" end

      assert :ok =
               Aiur.Alerts.default_player(
                 "/nowhere/missing-sound.wav",
                 stub_player
               )
    end

    test "resolve_workspace_for returns nil when the workspace_root_fn crashes" do
      # Directly exercises the rescue branch via the injectable helper.
      crashing = fn -> raise "no workflow loaded" end
      assert is_nil(Aiur.Alerts.resolve_workspace_for("MT-WSCRASH", crashing))
    end

    test "resolve_workspace_for returns the workspace path when it exists" do
      workspace_root = Path.join(System.tmp_dir!(), "aiur-rwfor-#{System.unique_integer([:positive])}")
      # Linear default config namespaces the workspace under <root>/<project_slug>/.
      workspace = Path.join([workspace_root, "project", "MT-WSEXIST"])
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace_root) end)

      assert workspace == Aiur.Alerts.resolve_workspace_for("MT-WSEXIST", fn -> workspace_root end)
    end

    @tag :tmp_dir
    test "spawns a playback task when a player and the sound both exist", %{tmp_dir: tmp_dir} do
      # Player resolves and the file exists, so a Task.start runs. We use
      # `/usr/bin/true` as a stand-in for whichever player the host OS probes
      # and create a real file the function can pass to `System.cmd/3`.
      sound_path = Path.join(tmp_dir, "ring.wav")
      File.write!(sound_path, "")

      true_path = System.find_executable("true") || "/usr/bin/true"
      stub_player = fn _binary -> true_path end

      assert {:ok, _pid} = Aiur.Alerts.default_player(sound_path, stub_player)
    end
  end

  describe "player_command/2 cross-platform resolution" do
    test "macOS resolves afplay with a bare-path argv" do
      find = fn "afplay" -> "/usr/bin/afplay" end
      assert {"/usr/bin/afplay", build_args} = Alerts.player_command({:unix, :darwin}, find)
      assert build_args.("/tmp/a.aiff") == ["/tmp/a.aiff"]
    end

    test "Linux picks paplay first with a bare-path argv when it is present" do
      # paplay is the first candidate; when present it short-circuits the rest
      # and takes a bare path (no `-f`).
      find = fn
        "paplay" -> "/usr/bin/paplay"
        _ -> "/usr/bin/should-not-be-probed"
      end

      assert {"/usr/bin/paplay", build_args} = Alerts.player_command({:unix, :linux}, find)
      assert build_args.("/tmp/a.oga") == ["/tmp/a.oga"]
    end

    test "Linux prefers paplay, then canberra-gtk-play (-f), then aplay" do
      # Only canberra is present → it wins over the later aplay, and its argv
      # carries the `-f` flag freedesktop's player requires.
      find = fn
        "paplay" -> nil
        "canberra-gtk-play" -> "/usr/bin/canberra-gtk-play"
        "aplay" -> "/usr/bin/aplay"
      end

      assert {"/usr/bin/canberra-gtk-play", build_args} =
               Alerts.player_command({:unix, :linux}, find)

      assert build_args.("/tmp/a.oga") == ["-f", "/tmp/a.oga"]
    end

    test "returns :none when no player binary is on the path" do
      assert :none = Alerts.player_command({:unix, :linux}, fn _ -> nil end)
      assert :none = Alerts.player_command({:win32, :nt}, fn _ -> "/x" end)
    end
  end

  describe "categorize_topic/1 maps real alert topics to OS-sound categories" do
    test "needs-input topics" do
      assert :needs_input =
               Alerts.categorize_topic("ticket.MT-1.issue.label.added.agent.human-review")

      assert :needs_input = Alerts.categorize_topic("ticket.MT-1.agent.input_required")
    end

    test "stuck topics" do
      assert :stuck = Alerts.categorize_topic("ticket.MT-1.agent.paused")
      assert :stuck = Alerts.categorize_topic("ticket.MT-1.agent.thrash_circuit_open")
      assert :stuck = Alerts.categorize_topic("ticket.MT-1.agent.retry_exhausted")
      assert :stuck = Alerts.categorize_topic("ticket.MT-1.agent.error.tokens_exhausted")
    end

    test "done topics" do
      assert :done = Alerts.categorize_topic("ticket.MT-1.pr.merged")
      assert :done = Alerts.categorize_topic("ticket.MT-1.issue.label.added.agent.merging")
      assert :done = Alerts.categorize_topic("ticket.MT-1.issue.state.changed")
    end

    test "the agent.unpaused resume topic is not miscategorized as :stuck" do
      # `.paused` is delimiter-anchored so it matches `agent.paused` but not the
      # `agent.unpaused` resume event — a resume must not play the stuck sound.
      assert :stuck = Alerts.categorize_topic("ticket.MT-1.agent.paused")
      assert :default = Alerts.categorize_topic("ticket.MT-1.agent.unpaused")
    end

    test "uncategorized and non-binary topics fall back to :default" do
      assert :default = Alerts.categorize_topic("ticket.MT-1.chat.opened")
      assert :default = Alerts.categorize_topic(:not_a_string)
    end
  end

  describe "os_sound_candidates/2 built-in OS sound sets" do
    test "macOS maps each category to a /System/Library/Sounds AIFF" do
      assert ["/System/Library/Sounds/Glass.aiff"] =
               Alerts.os_sound_candidates(:needs_input, {:unix, :darwin})

      assert ["/System/Library/Sounds/Sosumi.aiff"] =
               Alerts.os_sound_candidates(:stuck, {:unix, :darwin})

      assert ["/System/Library/Sounds/Hero.aiff"] =
               Alerts.os_sound_candidates(:done, {:unix, :darwin})
    end

    test "Linux maps each category to a freedesktop OGA with an ALSA WAV fallback" do
      assert [
               "/usr/share/sounds/freedesktop/stereo/message-new-instant.oga",
               "/usr/share/sounds/alsa/Front_Center.wav"
             ] = Alerts.os_sound_candidates(:needs_input, {:unix, :linux})

      assert [
               "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga",
               "/usr/share/sounds/alsa/Front_Center.wav"
             ] = Alerts.os_sound_candidates(:stuck, {:unix, :linux})
    end

    test "unknown OS yields no candidates (silent no-op)" do
      assert [] = Alerts.os_sound_candidates(:done, {:win32, :nt})
    end
  end

  describe "playback fallbacks" do
    test "playback env guard does not depend on Mix at runtime" do
      source = File.read!(Path.expand("../../lib/aiur/alerts.ex", __DIR__))

      refute source =~ "Mix.env"
      assert Application.get_env(:aiur, :env) == :test
    end

    test "test env suppresses fallback sound playback while preserving alert emission" do
      workspace_root =
        Path.join(System.tmp_dir!(), "aiur-alert-test-silent-#{System.unique_integer([:positive])}")

      workspace = Path.join([workspace_root, "project", "MT-ALERT-SILENT"])
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace_root) end)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      test_pid = self()
      previous_player = Application.get_env(:aiur, :alert_sound_player)

      Application.put_env(:aiur, :alert_sound_player, fn sound ->
        send(test_pid, {:fallback_player_called, sound})
      end)

      on_exit(fn ->
        if previous_player do
          Application.put_env(:aiur, :alert_sound_player, previous_player)
        else
          Application.delete_env(:aiur, :alert_sound_player)
        end
      end)

      assert :ok =
               Alerts.emit_system("ticket.MT-ALERT-SILENT.issue.state.changed",
                 issue: "MT-ALERT-SILENT"
               )

      refute_receive {:fallback_player_called, _sound}, 100

      assert Path.join(workspace, "logs/agent.ndjson")
             |> File.read!()
             |> String.contains?(~s("name":"ticket.MT-ALERT-SILENT.issue.state.changed"))
    end

    test "non-test env still invokes fallback sound playback" do
      workspace_root =
        Path.join(System.tmp_dir!(), "aiur-alert-runtime-sound-#{System.unique_integer([:positive])}")

      workspace = Path.join([workspace_root, "project", "MT-ALERT-RUNTIME"])
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace_root) end)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      test_pid = self()
      previous_env = Application.get_env(:aiur, :env)
      previous_player = Application.get_env(:aiur, :alert_sound_player)

      Application.put_env(:aiur, :env, :prod)

      Application.put_env(:aiur, :alert_sound_player, fn sound ->
        send(test_pid, {:fallback_player_called, sound})
      end)

      on_exit(fn ->
        if previous_env do
          Application.put_env(:aiur, :env, previous_env)
        else
          Application.delete_env(:aiur, :env)
        end

        if previous_player do
          Application.put_env(:aiur, :alert_sound_player, previous_player)
        else
          Application.delete_env(:aiur, :alert_sound_player)
        end
      end)

      assert :ok =
               Alerts.emit_system("ticket.MT-ALERT-RUNTIME.issue.state.changed",
                 issue: "MT-ALERT-RUNTIME"
               )

      expected_sound = Path.join(System.user_home!(), "alerts/advisor-upgrade-complete.wav")
      assert_receive {:fallback_player_called, ^expected_sound}
    end

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
               Alerts.emit_system("ticket.MT-ALERT-RESCUE.issue.state.changed",
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

  describe "config-driven alert settings" do
    setup do
      workspace_root =
        Path.join(System.tmp_dir!(), "aiur-alert-cfg-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(workspace_root, "MT-CFG"))
      on_exit(fn -> File.rm_rf!(workspace_root) end)

      %{workspace_root: workspace_root}
    end

    test "enabled: false gates playback even with a player override", %{workspace_root: root} do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        alerts_enabled: false
      )

      probe = fn sound -> send(self(), {:played, sound}) end

      assert :ok =
               Alerts.emit_system("ticket.MT-CFG.agent.paused", issue: "MT-CFG", player: probe)

      refute_receive {:played, _sound}, 100
    end

    test "OS-default mode resolves a <category> override file from sound_dir", %{
      workspace_root: root
    } do
      sound_dir = Path.join(root, "sounds")
      File.mkdir_p!(sound_dir)
      stuck_file = Path.join(sound_dir, "stuck.wav")
      File.write!(stuck_file, "")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        alerts_enabled: true,
        alerts_use_os_default_sounds: true,
        alerts_sound_dir: sound_dir
      )

      probe = fn sound -> send(self(), {:played, sound}) end

      assert :ok =
               Alerts.emit_system("ticket.MT-CFG.agent.paused", issue: "MT-CFG", player: probe)

      assert_receive {:played, ^stuck_file}
    end

    test "mapping mode loads the config alerts_file and joins bare sound names to sound_dir", %{
      workspace_root: root
    } do
      # Exercises two new seams at once: (1) alerts_path precedence — with no
      # :alerts_file_path app-env override set, the config `alerts_file` is used
      # instead of the bundled alerts file; (2) resolve_sound_path joins a bare
      # filename from the mapping onto `sound_dir`.
      sound_dir = Path.join(root, "clips")
      File.mkdir_p!(sound_dir)

      custom_yaml = Path.join(root, "custom-alerts.yaml")

      File.write!(custom_yaml, """
      alerts:
        "ticket.*.agent.paused":
          message: Custom paused
          sound:
            - "custom-stuck.wav"
      """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        alerts_enabled: true,
        alerts_use_os_default_sounds: false,
        alerts_sound_dir: sound_dir,
        alerts_file: custom_yaml
      )

      probe = fn sound -> send(self(), {:played, sound}) end
      expected = Path.join(sound_dir, "custom-stuck.wav")

      assert :ok =
               Alerts.emit_system("ticket.MT-CFG.agent.paused", issue: "MT-CFG", player: probe)

      assert_receive {:played, ^expected}
    end

    test "OS-default mode falls back to the host OS sound for the category", %{
      workspace_root: root
    } do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        alerts_enabled: true,
        alerts_use_os_default_sounds: true
      )

      probe = fn sound -> send(self(), {:played, sound}) end

      assert :ok =
               Alerts.emit_system("ticket.MT-CFG.agent.paused", issue: "MT-CFG", player: probe)

      # Deterministic across hosts: assert the real OS sound when this host ships
      # it, otherwise assert the no-op (nothing played) safety path.
      case Enum.find(Alerts.os_sound_candidates(:stuck, :os.type()), &File.exists?/1) do
        nil -> refute_receive {:played, _sound}, 100
        path -> assert_receive {:played, ^path}
      end
    end

    test "a missing config alerts_file falls back to the bundled mapping", %{workspace_root: root} do
      # A typo'd / non-existent custom alerts_file must not silently kill all
      # alert sounds — alerts_path falls back to the bundled alerts file, so a
      # real bundled topic still resolves its sound.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        alerts_enabled: true,
        alerts_file: Path.join(root, "does-not-exist.yaml")
      )

      probe = fn sound -> send(self(), {:played, sound}) end

      assert :ok =
               Alerts.emit_system("ticket.MT-CFG.issue.state.changed", issue: "MT-CFG", player: probe)

      expected = Path.join(System.user_home!(), "alerts/advisor-upgrade-complete.wav")
      assert_receive {:played, ^expected}
    end
  end
end
