defmodule Aiur.Orchestrator.PriorityControlTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchPolicy, PriorityControl, State}

  test "prioritizing persists priority:1 and updates the dispatch snapshot" do
    state = state_for(issue(labels: ["agent:todo", "priority:3"], priority: 3))
    test_pid = self()

    assert {:reply, {:ok, :prioritized}, updated_state} =
             PriorityControl.prioritize_agent_call(state, "1577",
               remove_label_fun: fn issue_id, label ->
                 send(test_pid, {:remove_label, issue_id, label})
                 :ok
               end,
               add_label_fun: fn issue_id, label ->
                 send(test_pid, {:add_label, issue_id, label})
                 :ok
               end,
               notify_dashboard_fun: fn _ -> :ok end
             )

    assert_receive {:remove_label, "1577", "priority:3"}
    assert_receive {:add_label, "1577", "priority:1"}
    assert updated_state.last_polled_issues["1577"].priority == 1
    assert updated_state.last_polled_issues["1577"].labels == ["agent:todo", "priority:1"]
    assert %State{running: %{"1577" => %{issue: %Issue{priority: 1}}}} = updated_state
  end

  test "deprioritizing removes every priority label and updates running state" do
    state = state_for(issue(labels: ["priority:1", "priority:3", "agent:in-progress"], priority: 1))
    test_pid = self()

    assert {:reply, {:ok, :deprioritized}, updated_state} =
             PriorityControl.deprioritize_agent_call(state, "1577",
               remove_label_fun: fn issue_id, label ->
                 send(test_pid, {:remove_label, issue_id, label})
                 :ok
               end,
               notify_dashboard_fun: fn _ -> :ok end
             )

    assert_receive {:remove_label, "1577", "priority:1"}
    assert_receive {:remove_label, "1577", "priority:3"}
    assert updated_state.last_polled_issues["1577"].priority == nil
    assert updated_state.last_polled_issues["1577"].labels == ["agent:in-progress"]
    assert %State{running: %{"1577" => %{issue: %Issue{priority: nil}}}} = updated_state
  end

  test "tracker failures leave the projection unchanged" do
    state = state_for(issue(labels: ["agent:todo"], priority: nil))

    assert {:reply, {:error, :forbidden}, ^state} =
             PriorityControl.prioritize_agent_call(state, "1577", add_label_fun: fn _, _ -> {:error, :forbidden} end)
  end

  test "prioritizing immediately moves the agent ahead in dispatch order" do
    normal = issue(id: "normal", identifier: "normal", created_at: ~U[2026-08-08 00:00:00Z])
    selected = issue(id: "selected", identifier: "selected", created_at: ~U[2026-08-09 00:00:00Z])

    assert {:reply, {:ok, :prioritized}, updated_state} =
             PriorityControl.prioritize_agent_call(state_for_issues([normal, selected]), "selected",
               add_label_fun: fn _issue_id, _label -> :ok end,
               notify_dashboard_fun: fn _ -> :ok end
             )

    assert ["selected", "normal"] =
             updated_state.last_polled_issues
             |> Map.values()
             |> DispatchPolicy.sort_issues_for_dispatch()
             |> Enum.map(& &1.id)
  end

  test "unknown agents never call the tracker" do
    state = state_for(issue())

    assert {:reply, {:error, :unknown_issue}, ^state} =
             PriorityControl.prioritize_agent_call(state, "missing", add_label_fun: fn _, _ -> flunk("unexpected tracker call") end)
  end

  defp state_for(issue) do
    %State{
      last_polled_issues: %{issue.id => issue},
      running: %{issue.id => %{identifier: issue.identifier, issue: issue}},
      retry_attempts: %{issue.id => %{identifier: issue.identifier, priority: issue.priority}}
    }
  end

  defp state_for_issues(issues) do
    %State{
      last_polled_issues: Map.new(issues, &{&1.id, &1}),
      running: Map.new(issues, &{&1.id, %{identifier: &1.identifier, issue: &1}}),
      retry_attempts: Map.new(issues, &{&1.id, %{identifier: &1.identifier, priority: &1.priority}})
    }
  end

  defp issue(attrs \\ []) do
    struct!(Issue, Keyword.merge([id: "1577", identifier: "1577", title: "Stream Deck"], attrs))
  end
end
