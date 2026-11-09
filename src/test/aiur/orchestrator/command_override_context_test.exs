defmodule Aiur.Orchestrator.CommandOverrideContextTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{CommandOverrideContext, State}

  test "active worker remains active with no capacity, while parked workers need resuming" do
    for {status, expected} <- [working: :active, sleeping: :active, paused: :resumable, deactivated: :resumable, completed: :resumable, unrecoverable: :unrecoverable] do
      state = %State{
        globally_paused: true,
        running: %{"id" => %{identifier: "6908", control: %{status: status}}}
      }

      assert CommandOverrideContext.read(state, "6908") == %{worker: expected, capacity: :full}
    end
  end

  test "an absent owner is unknown and fleet capacity is observed" do
    state = %State{max_concurrent_agents: 2, running: %{}}
    assert CommandOverrideContext.read(state, "6908") == %{worker: :unknown, capacity: :available}
  end
end
