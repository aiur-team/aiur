defmodule Aiur.DecisionEventActorTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionEvent

  test "round trips executor attribution on actor-bearing durable events" do
    assert {:ok, event} =
             DecisionEvent.new(
               :decision_deferred,
               "dec-executor-event",
               1,
               %{actor: %{kind: :executor, id: "executor-1"}},
               event_id: 1788,
               run_id: "run-executor-event",
               now: ~U[2026-08-10 12:00:00Z]
             )

    raw = event |> DecisionEvent.to_json_safe() |> Jason.encode!() |> Jason.decode!()

    assert raw["data"]["actor"] == %{"kind" => "executor", "id" => "executor-1"}
    assert {:ok, ^event} = DecisionEvent.from_json_safe(raw)
  end
end
