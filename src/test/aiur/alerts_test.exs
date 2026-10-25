defmodule Aiur.AlertsTest do
  use Aiur.TestSupport

  alias Aiur.{AgentLog, AlertFeed, AlertLedger, Alerts, Orchestrator, TrackerIdentity}
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.IssueSync

  test "emit_system writes a structured alert entry and selects a configured sound" do
    workspace_root =
      Aiur.TestSupport.tmp_root!("aiur-alerts")

    # Linear default config namespaces the workspace under <root>/<project_slug>/,
    # which is where resolve_workspace (via the issue:) now looks for the log dir.
    workspace = Path.join([workspace_root, "project", "MT-ALERT-1"])
    File.mkdir_p!(workspace)

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

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
    assert_receive {:played_sound, ^expected_sound}, 1000

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
    root = Aiur.TestSupport.tmp_root!("aiur-readiness-alert")
    workspace = Path.join([root, "project", "1474"])
    log_root = Path.join(root, "log")
    previous_log_file = Application.get_env(:aiur, :log_file)
    File.mkdir_p!(workspace)

    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    Aiur.TestSupport.put_runtime_state_dir!(log_root)

    on_exit(fn ->
      if previous_log_file do
        Application.put_env(:aiur, :log_file, previous_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end
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

  # The base-branch change announcement is a semantic event (structured
  # old -> new) delivered through the alert's Exchange payload, so agents
  # subscribed to `system.config.base_branch.changed` see one event carrying
  # both fields rather than a duplicate.
  test "exchange_payload fields ride the Exchange event" do
    :ok = Exchange.subscribe("system.config.base_branch.changed")

    assert :ok =
             Alerts.emit_system("system.config.base_branch.changed",
               message: "tracker.base_branch changed from develop to main",
               reason: "tracker.base_branch changed from develop to main",
               exchange_payload: %{old_base: "develop", new_base: "main", source: :system}
             )

    assert_receive {:event, event}, 500
    assert event.topic == "system.config.base_branch.changed"
    assert event.old_base == "develop"
    assert event.new_base == "main"
    assert event["message"] == "tracker.base_branch changed from develop to main"
  end

  # NOTE: Pre-Ticket-B, `emit_custom` rejected names starting with system
  # scopes (`task.*`, `agent.*`, `chat.*`). That gate moved to Ticket A's
  # `emit_event` tool allowlist — server-side `Alerts` no longer policies
  # this since the agent never reaches Alerts without going through the
  # tool first. Test retained for documentation purposes.

  test "task state transitions emit task alerts into the issue workspace log" do
    workspace_root =
      Aiur.TestSupport.tmp_root!("aiur-alert-state")

    # Resolved via the issue identifier, so it must match the repo-namespaced
    # layout (Linear default config → <root>/project/<issue>).
    workspace = Path.join([workspace_root, "project", "MT-ALERT-2"])
    File.mkdir_p!(workspace)

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

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
      Aiur.TestSupport.tmp_root!("aiur-alert-review")

    workspace = Path.join([workspace_root, "project", "MT-ALERT-REVIEW"])
    File.mkdir_p!(workspace)

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

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
      Aiur.TestSupport.tmp_root!("aiur-alert-tracker-pause")

    workspace = Path.join([workspace_root, "project", "MT-TRACKER-PAUSE"])
    File.mkdir_p!(workspace)

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)

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
      Aiur.TestSupport.tmp_root!("aiur-alert-central")

    original_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(log_root) end)
    Aiur.TestSupport.put_runtime_state_dir!(log_root)

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end
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
      Aiur.TestSupport.tmp_root!("aiur-alert-central-workspace")

    workspace = Path.join([workspace_root, "project", "MT-CENTRAL-WORKSPACE"])
    log_root = Path.join(workspace_root, "central")
    original_log_file = Application.get_env(:aiur, :log_file)
    File.mkdir_p!(workspace)
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)
    Aiur.TestSupport.put_runtime_state_dir!(log_root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end
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
      Aiur.TestSupport.tmp_root!("aiur-alert-fleet")

    original_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(log_root) end)
    Aiur.TestSupport.put_runtime_state_dir!(log_root)

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end
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
    log_root = Aiur.TestSupport.tmp_root!("aiur-takeover-alert")
    original_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(log_root) end)
    Aiur.TestSupport.put_runtime_state_dir!(log_root)

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end
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

  describe "definition_for_topic/1 glob matching" do
    setup do
      prev = Application.get_env(:aiur, :alerts_file_path)

      tmp_yaml = Aiur.TestSupport.tmp_root!("alerts_glob") <> ".yaml"

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
end
