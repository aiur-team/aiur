defmodule Aiur.Orchestrator.DispatchTriggerIntegrationTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.Hints
  alias Aiur.Orchestrator.{DispatchCandidates, Dispatcher, DispatchPolicy, IssueSync, PauseResume, State, StatusReport}

  setup do
    :ets.new(Hints.table_name(), [:named_table, :set])
    previous = Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)
    parent = self()
    Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn :lifecycle, event, _ -> send(parent, {:lifecycle, event}) end)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, previous), else: Application.delete_env(:aiur, :run_telemetry_lifecycle_recorder)
    end)

    :ok
  end

  test "status, candidates, issue sync, queued resume and both dispatcher gates share the effective trigger" do
    candidate = issue("3765-integration", state: "todo", blocked_by: [%{id: "3765-blocker", state: "ci-wait"}], priority: 1)
    other = issue("3765-other", state: "todo", priority: 2)
    state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1, last_polled_issues: %{candidate.id => candidate}}
    terminal = DispatchPolicy.terminal_state_set()

    assert DispatchCandidates.order([other, candidate], terminal) == [other, candidate]
    assert [held] = StatusReport.agent_statuses(state)
    assert held.waiting_reason == :waiting_for_dependency
    assert {:reply, {:error, :waiting_for_dependencies}, _} = resume(state, candidate)
    assert IssueSync.sync_todo_capacity_alert(state, [candidate, other]).todo_over_capacity_alert_active == false

    :ets.insert(Hints.table_name(), {candidate.id, {0, 0}, false, :pr_opened})

    assert DispatchCandidates.order([other, candidate], terminal) == [candidate, other]
    assert [ready] = StatusReport.agent_statuses(state)
    refute ready.waiting_reason == :waiting_for_dependency
    assert {:reply, {:tracker_io, _, :fetch_issue_states_by_ids, [[id]]}, _} = resume(state, candidate)
    assert id == candidate.id
    assert IssueSync.sync_todo_capacity_alert(state, [candidate, other]).todo_over_capacity_alert_active

    parent = self()

    dispatched =
      Dispatcher.dispatch_issue(state, candidate, nil, nil,
        issue_fetcher: fn [id] ->
          send(parent, {:refreshed, id})
          {:ok, [candidate]}
        end,
        blocked_by_hydrator: fn issue ->
          send(parent, {:hydrated, issue.id})
          {:ok, issue}
        end,
        runner: fn _, _, _ ->
          receive do
            :stop -> :ok
          end
        end
      )

    assert dispatched.running[candidate.id].optimistic_blockers == ["3765-blocker"]
    assert_received {:refreshed, "3765-integration"}
    assert_received {:hydrated, "3765-integration"}
    assert_received {:hydrated, "3765-integration"}
    assert_received {:lifecycle, %{event: "dispatch", optimistic_blockers: ["3765-blocker"]}}
    send(dispatched.running[candidate.id].pid, :stop)
  end

  test "a fully final dispatch records no optimistic blockers in the entry or event" do
    candidate = issue("3765-final", state: "todo", blocked_by: [%{id: "3765-done", state: "Done"}])
    state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

    dispatched =
      Dispatcher.dispatch_issue(state, candidate, nil, nil,
        issue_fetcher: fn _ -> {:ok, [candidate]} end,
        blocked_by_hydrator: fn issue -> {:ok, issue} end,
        runner: fn _, _, _ ->
          receive do
            :stop -> :ok
          end
        end
      )

    assert dispatched.running[candidate.id].optimistic_blockers == []
    assert_received {:lifecycle, %{event: "dispatch", optimistic_blockers: []}}
    send(dispatched.running[candidate.id].pid, :stop)
  end

  defp issue(id, attrs), do: struct!(Issue, Keyword.merge([id: id, identifier: "repo##{id}", title: id, state: "todo"], attrs))

  defp resume(state, candidate), do: PauseResume.tracker_control_call(state, :resume, candidate.identifier, {:queued_fetched, candidate}, {:ok, [candidate]})
end
