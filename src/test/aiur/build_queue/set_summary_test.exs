defmodule Aiur.BuildQueue.SetSummaryTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.SetSummary

  test "active, next, waiting and done preserve counts, holds and admission causes" do
    reasons = ["max_active_sets 1", "spill reserve 1 slots", "readiness unknown; may have ready work"]

    for cause <- reasons do
      reason = "queue_set_order: set 3 waits for set 1 (#{cause})"
      queues = [queue(4, [item(:completed), item(:cancelled)]), queue(2, [item(:promoted, reason)]), queue(1, [item(:ready)]), queue(0, [item(:claimed), item(:waiting)])]
      [active, next, waiting, done] = selected(queues, "1")
      assert {active.state, active.counts} == {:active, %{ready: 0, started: 1, done: 0}}
      assert {next.state, next.counts} == {:next, %{ready: 1, started: 0, done: 0}}
      assert {waiting.state, waiting.waiting_reason, waiting.counts.ready} == {:waiting, reason, 1}
      assert {done.state, done.counts.done} == {:done, 2}
      [held] = selected([%{next | held: true}], nil)
      assert {held.state, held.waiting_reason} == {:waiting, "held"}
    end
  end

  test "unknown evidence cannot become zero counts or next even with a known ready member" do
    [unknown, next] = selected([queue(0, [item(:unknown), item(:ready)]), queue(1, [item(:ready)])], "1")
    assert unknown.counts == %{ready: nil, started: nil, done: nil}
    assert {unknown.state, unknown.waiting_reason} == {:waiting, "readiness unknown"}
    assert next.state == :next
    [empty] = SetSummary.decorate([queue(0, [])], ["0"])
    assert empty.counts == %{ready: nil, started: nil, done: nil}
    assert {empty.state, empty.waiting_reason} == {:waiting, "readiness unknown"}
  end

  defp selected(queues, id), do: SetSummary.select_next(%{queues: SetSummary.decorate(queues, [])}, {:ok, id}).queues

  defp queue(rank, items), do: %{queue_id: to_string(rank), name: "set #{rank}", set_rank: rank, held: false, items: items}
  defp item(state, reason \\ nil), do: %{state: state, reason: reason, verdict: :ready}
end
