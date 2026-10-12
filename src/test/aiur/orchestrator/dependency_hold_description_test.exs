defmodule Aiur.Orchestrator.DependencyHoldDescriptionTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.Hints
  alias Aiur.Orchestrator.{DispatchPolicy, WaitingReason}
  alias Aiur.StartTrigger.ProgressStore

  test "waiting row evaluates approval prerequisites once for the hold and its description" do
    :ets.new(Hints.table_name(), [:named_table, :set])
    id = "hold-description-#{System.unique_integer([:positive])}"
    :ets.insert(Hints.table_name(), {id, {0, 0}, false, :pr_approved})
    blocker = %{id: id <> "-blocker", identifier: "12", state: "ci-wait"}
    store = Process.whereis(ProgressStore)
    :erlang.trace(store, true, [:receive])

    try do
      waiting = WaitingReason.describe(:waiting_for_dependency, %{issue_id: id, blocked_by: [blocker]})
      assert waiting.cause == [blocker]
      assert waiting.trigger == :pr_approved
      assert waiting.description == "blocked by open dependency #12 (ci-wait) [#12 needs pr_approved (now pr_opened)]; needs pr_approved"
      :sys.get_state(store)
      ref = :erlang.trace_delivered(store)
      receive_barrier({:trace_delivered, ^store, ^ref})
      {:messages, messages} = Process.info(self(), :messages)

      watches = Enum.filter(messages, &match?({:trace, ^store, :receive, {:"$gen_cast", {:watch, [id], _}}} when id == blocker.id, &1))
      assert length(watches) == 1
    after
      :erlang.trace(store, false, [:receive])
    end
  end

  test "a hold without remaining prerequisite details omits empty brackets" do
    candidate = %Issue{id: "no-held-prerequisites", blocked_by: []}
    text = DispatchPolicy.describe_dependency_hold(candidate, DispatchPolicy.terminal_state_set())
    assert text == "blocked by a non-terminal dependency; needs pr_merged"
    refute text =~ "[]"
  end
end
