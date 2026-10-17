defmodule Aiur.BuildQueue.SetSummaryTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.SetSummary

  test "active, next, waiting and done preserve counts, holds and admission causes" do
    reasons = ["max_active_sets 1", "spill reserve 1 slots", "readiness unknown; may have ready work"]

    for cause <- reasons do
      reason = "queue_set_order: set 3 waits for set 1 (#{cause})"
      queues = [queue(4, [item(:completed), item(:cancelled)]), queue(2, [item(:promoted, reason)]), queue(1, [item(:ready)]), queue(0, [item(:claimed), item(:waiting)])]
      [active, next, waiting, done] = selected(queues, "1")
      assert {active.state, active.counts} == {:active, %{ready: 0, startable: 0, started: 1, done: 0}}
      assert {next.state, next.counts} == {:next, %{ready: 1, startable: 1, started: 0, done: 0}}
      assert {waiting.state, waiting.waiting_reason, waiting.counts.ready} == {:waiting, reason, 1}
      assert {done.state, done.counts.done} == {:done, 2}
      [held] = selected([%{next | held: true}], nil)
      assert {held.state, held.waiting_reason} == {:waiting, "held"}
    end
  end

  test "unknown evidence cannot become zero counts or next even with a known ready member" do
    [unknown, next] = selected([queue(0, [item(:unknown), item(:ready)]), queue(1, [item(:ready)])], "1")
    assert unknown.counts == %{ready: nil, startable: nil, started: nil, done: nil}
    assert {unknown.state, unknown.waiting_reason} == {:waiting, "readiness unknown"}
    assert next.state == :next
    [empty] = SetSummary.decorate([queue(0, [])], ["0"])
    assert empty.counts == %{ready: nil, startable: nil, started: nil, done: nil}
    assert {empty.state, empty.waiting_reason} == {:waiting, "readiness unknown"}
  end

  test "native blocked members are not ready or startable and the largest blocker gates the most tickets" do
    blocked = %{item(:waiting) | number: 11, prerequisites: [%{number: 7, verdict: :pending}]}
    ready = %{item(:ready) | number: 13, prerequisites: [], downstream_open: 0}
    edges = [edge("7", "11"), edge("11", "12"), edge("7", "13")]

    [summary] =
      SetSummary.decorate(
        [queue(0, [blocked, ready]) |> Map.merge(%{edges: edges, open_member_ids: ["11", "12", "13"]})],
        []
      )

    assert summary.counts == %{ready: 1, startable: 1, started: 0, done: 0}
    assert summary.critical_path == %{number: 7, gates: 3}
  end

  defp selected(queues, id), do: SetSummary.select_next(%{queues: SetSummary.decorate(queues, [])}, {:ok, id}).queues

  defp queue(rank, items), do: %{queue_id: to_string(rank), name: "set #{rank}", set_rank: rank, held: false, items: items}
  defp item(state, reason \\ nil), do: %{state: state, reason: reason, verdict: if(state == :waiting, do: :waiting, else: :ready), prerequisites: [], number: nil, downstream_open: 0}
  defp edge(from, to), do: %Aiur.BuildQueue.Model.Edge{prerequisite: from, dependent: to, source: :native}
end
