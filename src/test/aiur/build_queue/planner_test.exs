Code.require_file("../../support/build_queue_planner_fixture.exs", __DIR__)

defmodule Aiur.BuildQueue.PlannerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Aiur.BuildQueue.Planner
  alias Aiur.BuildQueue.PlannerFixture, as: F

  test "ready marker-only item promotes with fresh evidence" do
    assert {[%{state: :ready, verdict: :ready}], [{:promote, "1"}]} = Planner.plan(F.input())
  end

  test "stale, missing, unknown and future observations cannot promote" do
    for changes <- [[observed_at_ms: 8_999], [observed_at_ms: 10_001], [open?: :unknown]] do
      assert {[%{state: :unknown}], []} = F.input() |> F.update_observation(changes) |> Planner.plan()
    end

    assert {[%{state: :unknown, reason: :observation_unavailable}], []} = Planner.plan(%{F.input() | observations: %{}})
    assert {[%{state: :ready}], [{:promote, "1"}]} = F.input() |> F.update_observation(observed_at_ms: 9_000) |> Planner.plan()
  end

  test "manual todo is overridden while successful or pending intent explains queue todo" do
    input = F.input() |> F.waiting() |> F.update_observation(labels: ~w(agent:queued agent:todo))
    assert {[%{state: :overridden}], [{:mark_override, "1"}]} = Planner.plan(input)

    for outcome <- [:ok, nil] do
      assert {[%{state: :promoted}], [{:begin_withdraw, "1"}]} = input |> F.intent(:promote, outcome: outcome) |> Planner.plan()
    end

    for changes <- [[outcome: {:error, :denied}], [target_labels: ["agent:queued"]], [recorded_at_ms: 10_001]] do
      assert {[%{state: :overridden}], [{:mark_override, "1"}]} = input |> F.intent(:promote, changes) |> Planner.plan()
    end
  end

  test "external removal holds once and matching withdrawal intent permits management" do
    input = F.input() |> F.update_item(promoted_at: DateTime.from_unix!(9_000, :millisecond))
    assert {[%{state: :held, reason: :external}], [{:mark_external_hold, "1"}]} = Planner.plan(input)
    assert {[%{state: :held}], []} = input |> F.update_item(hold: :external) |> Planner.plan()
    assert {[%{state: :ready}], [{:promote, "1"}]} = input |> F.intent(:withdraw) |> Planner.plan()
  end

  test "withdrawal requires a hold, unclaimed proof and fresh evidence; unavailable retains hold" do
    input = F.input() |> F.waiting() |> F.promoted()
    assert {[%{state: :promoted}], [{:begin_withdraw, "1"}]} = Planner.plan(input)
    input = F.apply_actions(input, [{:begin_withdraw, "1"}])

    for claims <- [:unavailable, %{}, %{"1" => :unavailable}] do
      assert {[%{state: :held, reason: :claim_check_unavailable}], []} = Planner.plan(%{input | claims: claims})
    end

    assert {[%{state: :promoted}], []} = Planner.plan(%{input | claims: %{"1" => {:declined, :capacity}}})

    input = %{input | claims: %{"1" => :unclaimed}}
    assert {[%{state: :promoted}], [{:withdraw, "1"}]} = Planner.plan(input)
    assert {[%{state: :promoted}], []} = input |> F.update_observation(observed_at_ms: 0) |> Planner.plan()
    assert {[%{state: :waiting}], [{:hold_release, "1"}]} = input |> F.apply_actions([{:withdraw, "1"}]) |> Planner.plan()
  end

  test "claim wins withdrawal race, releasing hold and latching attention" do
    input = F.input() |> F.waiting() |> F.promoted() |> F.apply_actions([{:begin_withdraw, "1"}])
    input = %{input | claims: %{"1" => :claimed}}
    actions = [{:hold_release, "1"}, {:attention_open, {:dependency_changed_after_start, "1"}}]
    assert {[%{state: :claimed}], ^actions} = Planner.plan(input)
    assert {[%{state: :claimed}], []} = input |> F.apply_actions(actions) |> Planner.plan()
  end

  test "parked markers and explicit holds prevent promotion using configured prefix" do
    for marker <- ~w(agent:paused agent:parked needs-triage human:todo epic:root) do
      input = F.input() |> F.update_observation(labels: ["agent:queued", marker])
      assert {[%{state: :held, reason: :parked_marker}], []} = Planner.plan(input)
      assert {[%{state: :ready}], [{:promote, "1"}]} = Planner.plan(%{input | opts: Keyword.put(input.opts, :promote_parked?, true)})
    end

    assert {[%{state: :held, reason: :operator}], []} = F.input() |> F.update_item(hold: :operator) |> Planner.plan()
    input = F.input()
    assert {[%{state: :held, reason: :queue_hold}], []} = Planner.plan(%{input | queues: Enum.map(input.queues, &%{&1 | held: true})})
    input = F.update_observation(input, labels: ~w(worker:queued worker:parked))
    assert {[%{state: :held}], []} = Planner.plan(%{input | opts: Keyword.put(input.opts, :label_prefix, "worker")})
  end

  test "unauthorized promotion opens attention once and resolves when cause clears" do
    input = F.input() |> F.promoted()
    input = %{input | claims: %{"1" => {:declined, :unauthorized}}}
    actions = [{:attention_open, {:promoted_unauthorized, "1"}}]
    assert {[%{state: :promoted_unauthorized}], ^actions} = Planner.plan(input)
    input = F.apply_actions(input, actions)
    assert {[%{state: :promoted_unauthorized}], []} = Planner.plan(input)
    assert {[%{state: :promoted}], [{:attention_resolve, {:promoted_unauthorized, "1"}}]} = Planner.plan(%{input | claims: %{"1" => :unclaimed}})
  end

  test "marker removal, closure, claims and saved overrides take precedence" do
    input = F.input() |> F.waiting() |> F.promoted()
    assert {[%{state: :removed}], [{:dequeue, "1"}]} = input |> F.update_observation(labels: []) |> Planner.plan()

    for {reason, state} <- [{"completed", :completed}, {"not_planned", :cancelled}, {"duplicate", :unknown}] do
      assert {[%{state: ^state}], []} = input |> F.update_observation(open?: false, state_reason: reason) |> Planner.plan()
    end

    for label <- ~w(agent:in-progress agent:rework agent:error) do
      assert {[%{state: :claimed}], []} = F.input() |> F.update_observation(labels: ["agent:queued", label]) |> Planner.plan()
    end

    assert {[%{state: :claimed}], []} = Planner.plan(%{F.input() | claims: %{"1" => :claimed}})
    assert {[%{state: :overridden}], []} = F.input() |> F.update_item(override: :manual_promotion) |> Planner.plan()
  end

  test "prerequisites wait, fail with latched attention, or stay unknown on missing and cyclic evidence" do
    input = F.input() |> F.waiting()
    assert {[%{state: :waiting}], []} = Planner.plan(input)
    failed = %{input | observations: Map.update!(input.observations, "2", &%{&1 | labels: ["agent:error"]})}
    actions = [{:attention_open, {{:prerequisite_failed, :agent_error}, "2"}}]
    assert {[%{state: :failed_prerequisite}], ^actions} = Planner.plan(failed)
    assert {[%{state: :failed_prerequisite}], []} = failed |> F.apply_actions(actions) |> Planner.plan()
    assert {[%{state: :unknown}], []} = Planner.plan(%{input | observations: Map.delete(input.observations, "2")})
    cycle = %{F.edge() | prerequisite: "1"}
    assert {[%{state: :unknown, verdict: {:unknown, [:cyclic]}}], []} = Planner.plan(%{F.input() | edges: [cycle]})
    satisfied = %{input | observations: Map.update!(input.observations, "2", &%{&1 | open?: false, state_reason: "completed"})}
    assert {[%{state: :ready}], [{:promote, "1"}]} = Planner.plan(satisfied)
  end

  test "promotion actions follow list rank regardless of input order" do
    input = F.input()
    items = [%{F.item("3") | position: 1}, %{F.item("2") | position: 0}, F.item("1")]
    observations = Map.new(~w(1 2 3), &{&1, F.observation(&1)})
    assert {states, [{:promote, "1"}, {:promote, "2"}, {:promote, "3"}]} = Planner.plan(%{input | items: items, observations: observations})
    assert Enum.map(states, & &1.issue_id) == ~w(1 2 3)
  end

  test "restored prerequisites release withdrawal hold without removing todo" do
    input = F.input() |> F.promoted() |> F.apply_actions([{:begin_withdraw, "1"}])
    assert {[%{state: :promoted}], [{:hold_release, "1"}]} = Planner.plan(input)
    assert {[%{state: :promoted}], []} = input |> F.apply_actions([{:hold_release, "1"}]) |> Planner.plan()
  end

  test "unknown prerequisite evidence never authorizes withdrawal" do
    input = F.input() |> F.waiting() |> F.promoted() |> F.apply_actions([{:begin_withdraw, "1"}])
    input = %{input | claims: %{"1" => :unclaimed}, observations: Map.delete(input.observations, "2")}
    assert {[%{state: :promoted, verdict: {:unknown, [:stale]}}], []} = Planner.plan(input)
  end

  test "promotions follow downstream rank across queues and union edges" do
    input = F.input()
    items = Enum.map(~w(1 2 3 4 5), &F.item/1)
    observations = Map.new(~w(1 2 3 4 5), &{&1, F.observation(&1)})
    edges = for {from, to} <- [{"1", "3"}, {"2", "4"}, {"4", "5"}], do: %{F.edge() | prerequisite: from, dependent: to}
    assert {states, [{:promote, "2"}, {:promote, "1"}]} = Planner.plan(%{input | items: Enum.reverse(items), observations: observations, edges: edges})
    assert Enum.map(states, & &1.issue_id) == ~w(2 1 4 3 5)
  end

  test "holds preserve failed prerequisite attention until its cause clears" do
    input = F.input() |> F.waiting() |> F.update_item(hold: :operator)
    input = %{input | observations: Map.update!(input.observations, "2", &%{&1 | labels: ["agent:error"]})}
    actions = [{:attention_open, {{:prerequisite_failed, :agent_error}, "2"}}]
    assert {[%{state: :held}], ^actions} = Planner.plan(input)
    input = F.apply_actions(input, actions)
    assert {[%{state: :held}], []} = Planner.plan(input)
    input = %{input | observations: Map.update!(input.observations, "2", &%{&1 | labels: []})}
    assert {[%{state: :held}], [{:attention_resolve, {{:prerequisite_failed, :agent_error}, "2"}}]} = Planner.plan(input)
    assert {[%{state: :held}], []} = F.input() |> F.promoted() |> F.update_item(hold: :operator) |> Planner.plan()
  end

  test "unknown evidence retains failure latches and planner leaves executor-owned latches alone" do
    input = F.input() |> F.waiting()
    key = {{:prerequisite_failed, :agent_error}, "2"}
    input = F.apply_actions(input, [{:attention_open, key}, {:attention_open, {:write_failed, "1"}}])
    input = %{input | observations: Map.delete(input.observations, "2")}
    assert {[%{state: :unknown}], []} = Planner.plan(input)
  end

  test "cached unauthorized decline latches after a planned promotion without a second action batch" do
    input = %{F.input() | claims: %{"1" => {:declined, :unauthorized}}}
    actions = [{:promote, "1"}, {:attention_open, {:promoted_unauthorized, "1"}}]
    assert {[%{state: :ready}], ^actions} = Planner.plan(input)
    assert {[%{state: :promoted_unauthorized}], []} = input |> F.apply_actions(actions) |> Planner.plan()
  end

  property "applied effects do not repeat actions" do
    check all(input <- F.generator()) do
      {_states, first} = Planner.plan(input)
      assert elem(Planner.plan(F.apply_actions(input, first)), 1) == []
    end
  end
end
