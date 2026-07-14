defmodule Aiur.AppServer.ProviderTurnLedgerTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.ProviderTurnLedger

  test "retired IDs survive an Aiur turn boundary on a reused provider session" do
    {:ok, store} = ProviderTurnLedger.start_store()
    on_exit(fn -> ProviderTurnLedger.stop_store(store) end)

    first_state = state(store, "turn-1")
    completed = %{"params" => %{"turn" => %{"id" => "turn-1"}}}
    ProviderTurnLedger.complete(first_state, completed)

    second_state = state(store, "turn-2")
    second_state = ProviderTurnLedger.register(second_state, %{"id" => "turn-1"})

    assert second_state.active_turn_ids == MapSet.new(["turn-2"])
    assert second_state.retired_turn_ids == MapSet.new(["turn-1"])
    assert second_state.outstanding_turns == 1
  end

  test "the anonymous completion guard survives an Aiur turn boundary" do
    {:ok, store} = ProviderTurnLedger.start_store()
    on_exit(fn -> ProviderTurnLedger.stop_store(store) end)

    first_state = ProviderTurnLedger.complete(state(store, "turn-1"), %{})
    second_state = ProviderTurnLedger.complete(state(store, "turn-2"), %{})

    assert first_state.active_turn_ids == MapSet.new()
    assert second_state.active_turn_ids == MapSet.new(["turn-2"])
    assert second_state.anonymous_completion_consumed?
    assert second_state.outstanding_turns == 1
  end

  test "the store exits with an abnormally retired session owner" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, store} = ProviderTurnLedger.start_store()
        send(parent, {:store, store})
        Process.sleep(:infinity)
      end)

    assert_receive {:store, store}
    ref = Process.monitor(store)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^store, :killed}
  end

  defp state(store, turn_id) do
    Map.merge(
      %{
        active_turn_ids: MapSet.new([turn_id]),
        accepted_turn_ids: MapSet.new(),
        current_turn_id: turn_id,
        outstanding_turns: 1,
        provider_turn_store: store
      },
      ProviderTurnLedger.guards(store)
    )
  end
end
