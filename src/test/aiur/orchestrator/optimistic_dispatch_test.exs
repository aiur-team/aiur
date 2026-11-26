defmodule Aiur.Orchestrator.OptimisticDispatchTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.{CommentWake, Dispatcher, EventTopics, MergedTicketReconciler, OptimisticDispatch, OptimisticLedger, State, TrackerTasks}
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.StartTrigger.ProgressStore
  alias Aiur.TestCleanup

  setup do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, OptimisticLedger)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, OptimisticLedger) end)
    path = Path.join(System.tmp_dir!(), "optimistic-dispatch-#{System.unique_integer([:positive])}/starts.json")
    on_exit(fn -> TestCleanup.rm_rf!(Path.dirname(path)) end)
    workflow_path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(workflow_path, File.read!(workflow_path) <> "\nbuild_queue:\n  start_trigger: pr_opened\n")
    :ok = Aiur.WorkflowStore.force_reload()
    parent = self()
    Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn :lifecycle, attrs, _ -> send(parent, {:lifecycle, attrs}) end)
    on_exit(fn -> Application.delete_env(:aiur, :run_telemetry_lifecycle_recorder) end)
    {:ok, path: path, parent: parent}
  end

  defp record(ticket) do
    assert {:ok, row} = OptimisticLedger.get(ticket)
    row
  end

  defp open_records do
    assert {:ok, rows} = OptimisticLedger.open_records()
    rows
  end

  defp start(path), do: start_supervised!({OptimisticLedger, path: path, alert: fn _, _ -> :ok end})

  defp candidate do
    id = "optimistic-#{System.unique_integer([:positive])}"
    %Issue{id: id, identifier: id, state: "todo", selected_backend: "codex"}
  end

  defp prepared(issue, evidence) do
    assert {:ok, issue} = OptimisticDispatch.prepare(issue, evidence, blocker_subscriber: fn _, _ -> :ok end)
    issue
  end

  defp dispatch(issue, parent, options \\ []) do
    options =
      Keyword.put(options, :runner, fn started_issue, _, opts ->
        send(parent, {:started_issue, started_issue})
        send(parent, {:started, opts})
        :ok
      end)

    Dispatcher.do_dispatch_issue(%State{max_concurrent_agents: 1, effective_concurrent_agents: 1}, issue, nil, nil, options)
  end

  test "two optimistic blockers write one attempt and one matching lifecycle point", %{path: path, parent: parent} do
    start(path)
    issue = candidate()
    ids = Enum.map(1..2, fn _ -> to_string(System.unique_integer([:positive])) end)

    for {id, number, sha} <- [{hd(ids), 41, String.duplicate("a", 40)}, {List.last(ids), 42, String.duplicate("b", 40)}] do
      ProgressStore.record(id, %{pr_number: number, head_sha: sha, stage: :pr_ci_green})
    end

    :sys.get_state(ProgressStore)
    blockers = Enum.map(ids, &%{id: &1, identifier: &1, state: "human-review"})
    issue = %{issue | blocked_by: blockers}

    evidence =
      Enum.map(ids, fn id ->
        facts = ProgressStore.lookup(id)
        %{identifier: id, pr_number: facts.pr_number, head_ref: "refs/heads/aiur/#{id}-start", head_sha: facts.head_sha}
      end)

    issue = prepared(issue, evidence)
    state = dispatch(issue, parent)
    receive_barrier({:started, opts})
    assert Map.has_key?(state.running, issue.id)
    assert_received {:lifecycle, %{event: "dispatch", attempt_id: attempt}}
    assert_received {:lifecycle, %{event: "optimistic_start", attempt_id: ^attempt, blockers: ^ids, blocker_prs: [41, 42]}}
    refute_received {:lifecycle, %{event: "optimistic_start"}}
    assert Keyword.fetch!(opts, :telemetry_attempt_id) == attempt
    record = record(issue.identifier)
    assert record["attempt_id"] == attempt
    assert record["start_trigger"] == "pr_opened"

    assert Enum.map(record["blockers"], &Map.take(&1, ["id", "pr_number", "pr_head_sha_at_start", "pr_state"])) == [
             %{"id" => hd(ids), "pr_number" => 41, "pr_head_sha_at_start" => String.duplicate("a", 40), "pr_state" => "open"},
             %{"id" => List.last(ids), "pr_number" => 42, "pr_head_sha_at_start" => String.duplicate("b", 40), "pr_state" => "open"}
           ]

    assert length(open_records()) == 1
  end

  test "ledger keeps evaluated fallback evidence when progress changes before spawn", %{path: path, parent: parent} do
    start(path)
    issue = candidate()
    identifier = to_string(System.unique_integer([:positive]))
    id = issue.id <> "-blocker"
    issue = %{issue | blocked_by: [%{id: id, identifier: identifier, state: "human-review"}]}
    original_sha = String.duplicate("a", 40)
    original_ref = "refs/heads/aiur/#{identifier}-original"
    ProgressStore.record(id, %{pr_number: 41, stage: :pr_opened})
    :sys.get_state(ProgressStore)

    assert {:ok, issue} =
             OptimisticDispatch.prepare_for_dispatch(issue,
               blocker_subscriber: fn _, _ -> :ok end,
               blocker_ref_lookup: fn ^identifier ->
                 ProgressStore.record(id, %{pr_number: 42, head_sha: String.duplicate("b", 40), head_ref: "refs/heads/aiur/#{identifier}-new", stage: :pr_ci_green})
                 :sys.get_state(ProgressStore)
                 %{ref: original_ref, sha: original_sha}
               end
             )

    ProgressStore.record(id, %{pr_number: 42, stage: :pr_merged})
    :sys.get_state(ProgressStore)
    advanced_sha = String.duplicate("b", 40)
    assert %{pr_number: 42, head_sha: ^advanced_sha, stage: :pr_merged} = ProgressStore.lookup(id)
    started_at = issue.optimistic_start.started_at
    assert [%{sha: ^original_sha, ref: ^original_ref, pr_number: 41}] = issue.optimistic_start.blockers
    dispatch(issue, parent)
    receive_barrier({:started, _})
    assert_received {:lifecycle, %{event: "optimistic_start", blockers: [^identifier], blocker_prs: [41]}}
    row = record(issue.identifier)
    assert row["started_at_ms"] == DateTime.to_unix(started_at, :millisecond)

    assert [%{"id" => ^identifier, "pr_number" => 41, "pr_head_sha_at_start" => ^original_sha, "pr_head_ref_at_start" => ^original_ref, "last_head_sha" => ^original_sha, "pr_state" => "merged"}] =
             row["blockers"]
  end

  test "raw prevalidated issue prepares its optimistic start in the shared dispatch path", %{path: path, parent: parent} do
    start(path)
    issue = candidate()
    blocker = to_string(System.unique_integer([:positive]))
    issue = %{issue | blocked_by: [%{id: blocker, identifier: blocker, state: "human-review"}]}
    sha = String.duplicate("c", 40)
    ref = "refs/heads/aiur/#{blocker}-manual"
    ProgressStore.record(blocker, %{pr_number: 50, stage: :pr_opened})
    :sys.get_state(ProgressStore)
    assert issue.optimistic_start == nil
    state = dispatch(issue, parent, blocker_subscriber: fn _, _ -> :ok end, blocker_ref_lookup: fn _ -> %{ref: ref, sha: sha} end)
    receive_barrier({:started, _})
    assert_received {:started_issue, %{optimistic_start: %{blockers: [%{sha: ^sha, ref: ^ref}]}}}
    assert Map.has_key?(state.running, issue.id)
    assert [%{"pr_head_sha_at_start" => ^sha, "pr_head_ref_at_start" => ^ref}] = record(issue.identifier)["blockers"]
  end

  test "normal dispatch starts the runner without ledger writes or optimistic telemetry", %{path: path, parent: parent} do
    start(path)
    issue = candidate()
    dispatch(issue, parent)
    receive_barrier({:started, _})
    assert_received {:lifecycle, %{event: "dispatch"}}
    refute_received {:lifecycle, %{event: "optimistic_start"}}
    assert record(issue.identifier) == nil
    refute File.exists?(path)
  end

  test "corrupt ledger does not prevent optimistic runner start", %{path: path, parent: parent} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "broken")
    start(path)
    issue = candidate()
    blocker = to_string(System.unique_integer([:positive]))
    issue = %{issue | blocked_by: [%{id: blocker, identifier: blocker, state: "human-review"}]}
    issue = prepared(issue, [%{identifier: blocker, pr_number: 41, head_ref: "refs/heads/aiur/#{blocker}-start", head_sha: String.duplicate("a", 40)}])
    state = dispatch(issue, parent)
    receive_barrier({:started, _})
    assert Map.has_key?(state.running, issue.id)
    assert_received {:lifecycle, %{event: "optimistic_start"}}
    assert {:error, :ledger_unavailable} = OptimisticLedger.record_start(issue.identifier, %{})
    assert File.read!(path) == "broken"
  end

  test "dependent merge route closes the ledger record", %{path: path} do
    start(path)
    issue = %{candidate() | identifier: "1570"}
    OptimisticLedger.record_start(issue.identifier, %{attempt_id: "merge", start_trigger: :pr_opened, started_at_ms: 100, blockers: [%{"id" => "12"}]})
    EventTopics.route(%State{}, %{topic: "ticket.#{issue.identifier}.pr.merged", pr: %{"body" => "Closes #1570", "merged_by" => %{"login" => "someone"}}})
    assert record(issue.identifier)["outcome"] == "merged"
    assert record(issue.identifier)["status"] == "closed"
  end

  test "poll-confirmed merge uses the same ledger closure as the event route", %{path: path} do
    start(path)
    issue = %{candidate() | identifier: "1570"}
    OptimisticLedger.record_start(issue.identifier, %{attempt_id: "merge", start_trigger: :pr_opened, started_at_ms: 100, blockers: [%{"id" => "12"}]})
    OptimisticLedger.bump(issue.identifier, :parks, 1)
    CommentWake.mark_pr_merged_issue_done(%State{}, issue.identifier, pr_body: "Closes #1570", merged_by_login: "someone")
    assert record(issue.identifier)["outcome"] == "merged_after_redo"
  end

  test "poll-confirmed merge closes its attempt even when another PR remains", %{path: path} do
    start(path)
    issue = %{candidate() | identifier: "1570", state: "in-progress"}
    OptimisticLedger.record_start(issue.identifier, %{attempt_id: "merge", start_trigger: :pr_opened, started_at_ms: 100, blockers: [%{"id" => "12"}]})
    now = DateTime.utc_now()

    merge = %Aiur.RecentMerge{
      id: "owner/repo#1600",
      repository: "owner/repo",
      number: 1600,
      url: "https://example.test/pr/1600",
      summary: "Closes #1570",
      merged_at: now,
      observation_source: :github_events,
      backfilled?: false,
      live_observed?: true,
      first_observed_at: now,
      last_observed_at: now,
      content_hash: "hash"
    }

    {state, []} =
      MergedTicketReconciler.reconcile(%State{snapshot_key: self()}, [issue],
        recent_merges_fun: fn -> [merge] end,
        now_fun: fn -> now end,
        update_issue_state_fun: fn _, _, _ -> :ok end,
        emit_alert_fun: fn _, _ -> :ok end,
        open_pull_requests_fun: fn _ -> {:ok, [%{"number" => 1601, "draft" => false, "review_decision" => "REVIEW_REQUIRED"}]} end
      )

    assert map_size(state.tracker_tasks) == 1
    assert record(issue.identifier)["outcome"] == "merged"
    TrackerTasks.stop(state)
  end

  test "optimistic telemetry preserves PR identities and filters unapproved metadata" do
    assert :ok = Lifecycle.record("10", "attempt", :optimistic_start, :point, %{start_trigger: :pr_opened, blockers: ["12"], blocker_prs: [50, nil], secret: "discard"})
    assert_received {:lifecycle, attrs}
    assert attrs.event == "optimistic_start"
    assert attrs.start_trigger == "pr_opened"
    assert attrs.blockers == ["12"]
    assert attrs.blocker_prs == [50, nil]
    refute Map.has_key?(attrs, :secret)
  end
end
