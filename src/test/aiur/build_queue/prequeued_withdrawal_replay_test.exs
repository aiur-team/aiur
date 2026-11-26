Code.require_file("../../support/build_queue_planner_fixture.exs", __DIR__)

defmodule Aiur.BuildQueue.PrequeuedWithdrawalReplayTest do
  @moduledoc "Replays MP-E1 AC12 (#4700) through Reconcile.plan/2: a stale pre-withdraw observation must not override T2."
  use ExUnit.Case, async: false
  alias Aiur.BuildQueue.{Hints, Model.Edge, Model.Intent, PlannerFixture, Reconcile}
  alias Aiur.Config.Schema
  alias Aiur.StartTrigger.ProgressStore

  defmodule Tracker do
    def issue_closure(id, _age), do: {:ok, Map.get(Process.get(:replay_closures, %{}), id, %{open?: true, state_reason: nil})}
    def blocked_by(_id), do: {:ok, []}
    def status(ids), do: Map.new(ids, &{&1, :unclaimed})
  end

  setup do
    if is_nil(Process.whereis(ProgressStore)), do: start_supervised!(ProgressStore)
    if :ets.whereis(Hints.table_name()) == :undefined, do: :ets.new(Hints.table_name(), [:named_table, :set, :public])
    :ok
  end

  test "T2's pre-existing todo is withdrawn, a stale reconcile keeps it managed, and T1's close promotes it" do
    # `queue add T1`, then `queue add T2 --after T1` while T2 already carries agent:todo (reconcile 4).
    marks = for {id, outcome} <- [{"mark-request", nil}, {"mark-attempt", :ok}], do: intent(id, :mark, ~w(agent:queued agent:todo), 1_000, outcome, true)
    document = %{queues: PlannerFixture.input().queues, items: [item("t1", 0), item("t2", 1)], edges: [%Edge{prerequisite: "t1", dependent: "t2", source: :list}], intents: marks, latches: []}
    settings = %Schema{build_queue: %Schema.BuildQueue{start_trigger: "pr_merged"}, polling: %Schema.Polling{}}

    state = %{
      document: document,
      settings: settings,
      tracker: Tracker,
      claim_probe: Tracker,
      holds: MapSet.new(),
      clock: fn -> 9_300 end,
      reconciles: 8,
      intent_reconciles: Map.new(marks, &{&1.id, 4})
    }

    stale = observations(9_000, %{"t1" => ~w(agent:queued agent:in-progress), "t2" => ~w(agent:queued agent:todo)})

    # Reconcile 8: the first fresh observation shows the pre-existing todo, so the queue withdraws it.
    {_, actions, _, _, holds, _, _} = Reconcile.plan(state, stale)
    assert {:withdraw, "t2"} in actions
    withdraw = intent("withdraw", :withdraw, ~w(agent:queued), 9_345, :ok, false)
    state = %{state | holds: holds, reconciles: 9, document: %{document | intents: marks ++ [withdraw]}, intent_reconciles: Map.put(state.intent_reconciles, "withdraw", 8)}

    # Reconcile 9 reuses the pre-withdraw observation; the marks are outside the 2-reconcile window.
    {projections, actions, _, _, holds, _, _} = Reconcile.plan(%{state | clock: fn -> 10_000 end}, stale)
    refute {:mark_override, "t2"} in actions
    refute state_of(projections, "t2") == :overridden

    # T1 completes; the next fresh listing omits it and shows T2 with only agent:queued.
    Process.put(:replay_closures, %{"t1" => %{open?: false, state_reason: "completed"}})
    fresh = observations(10_500, %{"t2" => ~w(agent:queued)})
    state = %{state | holds: holds, reconciles: 10, clock: fn -> 10_600 end}
    {_, actions, _, _, holds, _, _} = Reconcile.plan(state, fresh)
    holds = Enum.reduce(for({:hold_release, id} <- actions, do: id), holds, &MapSet.delete(&2, &1))

    {projections, actions, _, _, _, _, _} = Reconcile.plan(%{state | holds: holds, reconciles: 11}, fresh)
    assert {:promote, "t2"} in actions
    assert state_of(projections, "t2") == :ready
  end

  defp item(id, position), do: %{PlannerFixture.item(id) | position: position}

  defp intent(id, action, labels, at, outcome, preexisting),
    do: %Intent{id: id, issue_id: "t2", action: action, target_labels: labels, recorded_at_ms: at, outcome: outcome, preexisting_todo?: preexisting}

  defp observations(at, labels), do: Map.new(labels, fn {id, row} -> {id, %{PlannerFixture.observation(id) | labels: row, observed_at_ms: at}} end)
  defp state_of(projections, id), do: Enum.find(projections, &(&1.issue_id == id)).state
end
