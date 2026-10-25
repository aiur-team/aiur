defmodule Aiur.Orchestrator.SpendCap.StopTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.SpendCap.Stop
  alias Aiur.Orchestrator.State
  alias Aiur.TestSupport.GroupedScopes, as: GS

  test "stops only the running agent with the exact tracker identity and reports budget_exhausted" do
    identity = GS.identity(5693)
    other = GS.identity(77)

    running = %{
      "node-5693" => %{identifier: "5693", tracker_identity: identity},
      "node-77" => %{identifier: "77", tracker_identity: other}
    }

    teardown = fn state, issue_id, cleanup?, reason ->
      send(self(), {:teardown, issue_id, cleanup?, reason})
      %{state | running: Map.delete(state.running, issue_id)}
    end

    assert {:ok, :budget_exhausted, next} = Stop.run(%State{running: running}, identity, teardown)
    assert_receive {:teardown, "node-5693", true, :budget_exhausted}, 1_000
    assert Map.keys(next.running) == ["node-77"]
  end

  test "a repeated stop after teardown remains an idempotent budget_exhausted result" do
    teardown = fn _state, _issue_id, _cleanup?, _reason -> flunk("nothing should be torn down") end

    assert {:ok, :budget_exhausted, %State{}} = Stop.run(%State{}, GS.identity(5693), teardown)
  end

  test "an ambiguous running identity fails closed instead of reporting a stop" do
    identity = GS.identity(5693)

    running = %{
      "node-a" => %{identifier: "5693", tracker_identity: identity},
      "node-b" => %{identifier: "5693", tracker_identity: identity}
    }

    teardown = fn _state, _issue_id, _cleanup?, _reason -> flunk("ambiguous agents must not be torn down") end

    assert {:error, :ambiguous_identifier, %State{running: ^running}} =
             Stop.run(%State{running: running}, identity, teardown)
  end

  test "same-numbered tickets in another repository are never stopped" do
    identity = GS.identity(5693)
    fork = GS.identity("someone", "fork", 5693)

    running = %{
      "node-main" => %{identifier: "5693", tracker_identity: identity},
      "node-fork" => %{identifier: "5693", tracker_identity: fork}
    }

    teardown = fn state, issue_id, true, :budget_exhausted ->
      send(self(), {:teardown, issue_id})
      %{state | running: Map.delete(state.running, issue_id)}
    end

    assert {:ok, :budget_exhausted, next} =
             Stop.run(%State{running: running}, identity, teardown)

    assert_receive {:teardown, "node-main"}, 1_000
    assert next.running == %{"node-fork" => running["node-fork"]}
  end
end
