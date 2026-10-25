defmodule Aiur.Orchestrator.StatusReportBatchingTest do
  use Aiur.TestSupport

  alias Aiur.DecisionStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport.AgentStatuses
  alias Aiur.Orchestrator.StatusReport.SnapshotPayload

  test "agent status batches decision reads for fifty idle tickets" do
    state = idle_state(50)

    {statuses, batches} =
      count_decision_batches(fn -> AgentStatuses.agent_statuses(state) end)

    assert length(statuses) == 50
    assert [identifiers] = batches
    assert length(identifiers) == 50
    assert Enum.sort(identifiers) == Enum.sort(Enum.map(1..50, &"BT-#{&1}"))
  end

  test "snapshot payload batches decision reads for fifty idle tickets" do
    state = idle_state(50)

    {payload, batches} =
      count_decision_batches(fn -> SnapshotPayload.snapshot_payload(state) end)

    assert length(payload.idle) == 50
    assert [identifiers] = batches
    assert length(identifiers) == 50
    assert Enum.sort(identifiers) == Enum.sort(Enum.map(1..50, &"BT-#{&1}"))
  end

  defp idle_state(count) do
    issues =
      Map.new(1..count, fn number ->
        id = "issue-#{number}"

        {id,
         %Issue{
           id: id,
           identifier: "BT-#{number}",
           state: "todo",
           labels: []
         }}
      end)

    %State{last_polled_issues: issues, candidate_snapshot_fresh?: true}
  end

  defp count_decision_batches(fun) do
    store = Process.whereis(DecisionStore)
    assert is_pid(store)
    :erlang.trace(store, true, [:receive, {:tracer, self()}])

    try do
      result = fun.()
      delivery = :erlang.trace_delivered(store)
      assert_receive {:trace_delivered, ^store, ^delivery}, 1_000
      {result, collect_batches(store, [])}
    after
      :erlang.trace(store, false, [:receive])
    end
  end

  defp collect_batches(store, batches) do
    receive do
      {:trace, ^store, :receive, {:"$gen_call", _from, {:open_blocking_decision_ids_by_ticket, identifiers}}} ->
        collect_batches(store, if(targeted?(identifiers), do: [identifiers | batches], else: batches))

      {:trace, ^store, :receive, {:"$gen_call", _from, {:open_blocking_decision_ids, identifiers}}} ->
        collect_batches(store, if(targeted?(identifiers), do: [:individual | batches], else: batches))
    after
      0 -> Enum.reverse(batches)
    end
  end

  defp targeted?(identifiers),
    do: Enum.any?(identifiers, fn id -> is_binary(id) and String.starts_with?(id, "BT-") end)
end
