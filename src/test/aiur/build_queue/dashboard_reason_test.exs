defmodule Aiur.BuildQueue.DashboardReasonTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.{Model, ReadModel}
  alias Aiur.Config.Schema

  test "read model carries the held cause and replaces it when its observation goes stale" do
    state = state()
    assert [%{reason: :parked_marker, state: :held}] = hd(ReadModel.build(state).queues).items
    stale = %{state | clock: fn -> 200_000 end}
    assert [%{reason: :observation_unavailable, state: :unknown, rank: nil}] = hd(ReadModel.build(stale).queues).items
  end

  test "current unknown projections preserve their specific cause and hide rank" do
    state = state()

    for reason <- [:marker_pending, :closed_reason, [:cyclic]] do
      projection = %{hd(state.projections) | state: :unknown, reason: reason, verdict: {:unknown, [reason]}}
      result = state |> Map.put(:projections, [projection]) |> ReadModel.build() |> Map.fetch!(:queues) |> hd() |> Map.fetch!(:items) |> hd()
      assert result.reason == reason
      assert result.verdict == :unknown
      assert result.rank == nil
    end
  end

  defp state do
    now = ~U[2026-10-09 00:00:00Z]
    queue = %Model.Queue{id: "q-abcd", name: "Next", kind: :list, root: nil, held: false, generation: 0, created_at: now}
    item = %Model.Item{issue_id: "1", queue_id: queue.id, position: 1, hold: nil, override: nil, promoted_at: nil, added_at: now}
    document = %{queues: [queue], items: [item], edges: [], latches: [], intents: []}
    observation = %Model.Observation{issue_id: "1", open?: true, labels: ["agent:parked"], state_reason: nil, pr: nil, observed_at_ms: 1_000}
    settings = %Schema{build_queue: %Schema.BuildQueue{}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{interval_seconds: 60}}
    projection = %{issue_id: "1", state: :held, reason: :parked_marker, verdict: :ready, rank: {0, 5, 1, 0, "1"}}

    %{
      clock: fn -> 2_000 end,
      status: :running,
      document: document,
      projections: [projection],
      observations: %{"1" => observation},
      settings: settings,
      build_order_projection: :absent_dashboard_projection
    }
  end
end
