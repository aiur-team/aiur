defmodule SymphonyElixir.TUI.StateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TUI.State

  test "selects the first running agent by default" do
    state = State.new(snapshot_source: fn -> snapshot(["A-1", "A-2"]) end, refresh_ms: 1_000)

    assert state.selected_index == 0
  end

  test "does not select an empty running list" do
    state = State.new(snapshot_source: fn -> snapshot([]) end, refresh_ms: 1_000)

    assert state.selected_index == nil
  end

  test "moves selection down and up with clamping" do
    state = State.new(snapshot_source: fn -> snapshot(["A-1", "A-2"]) end, refresh_ms: 1_000)

    assert state |> State.select_next() |> Map.fetch!(:selected_index) == 1
    assert state |> State.select_next() |> State.select_next() |> Map.fetch!(:selected_index) == 1
    assert state |> State.select_next() |> State.select_previous() |> Map.fetch!(:selected_index) == 0
    assert state |> State.select_previous() |> Map.fetch!(:selected_index) == 0
  end

  test "clamps selection after refresh removes agents" do
    parent = self()

    snapshot_source = fn ->
      send(parent, :snapshot_requested)

      receive do
        {:snapshot, identifiers} -> snapshot(identifiers)
      end
    end

    send(self(), {:snapshot, ["A-1", "A-2"]})
    state = State.new(snapshot_source: snapshot_source, refresh_ms: 1_000)
    assert_received :snapshot_requested

    state = State.select_next(state)
    assert state.selected_index == 1

    send(self(), {:snapshot, ["A-1"]})
    state = State.refresh(state)
    assert_received :snapshot_requested

    assert state.selected_index == 0

    send(self(), {:snapshot, []})
    state = State.refresh(state)
    assert_received :snapshot_requested

    assert state.selected_index == nil
  end

  defp snapshot(identifiers) do
    {:ok,
     %{
       running: Enum.map(identifiers, &%{identifier: &1}),
       retrying: [],
       agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
     }}
  end
end
