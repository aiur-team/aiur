defmodule SymphonyElixir.TUI.AppTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias SymphonyElixir.TUI.{App, State}

  test "handles j and down as next selection" do
    state = state(["MT-101", "MT-102"])

    assert {:noreply, %{selected_index: 1}} = App.handle_event(key("j"), state)
    assert {:noreply, %{selected_index: 1}} = App.handle_event(key("down"), state)
  end

  test "handles k and up as previous selection" do
    state = state(["MT-101", "MT-102"]) |> State.select_next()

    assert {:noreply, %{selected_index: 0}} = App.handle_event(key("k"), state)
    assert {:noreply, %{selected_index: 0}} = App.handle_event(key("up"), state)
  end

  test "q stops the TUI" do
    state = state(["MT-101"])

    assert {:stop, ^state} = App.handle_event(key("q"), state)
  end

  test "ctrl-c stops the TUI" do
    state = state(["MT-101"])

    assert {:stop, ^state} = App.handle_event(%Key{code: "c", kind: "press", modifiers: ["ctrl"]}, state)
  end

  test "ignored keys do not render" do
    state = state(["MT-101"])

    assert {:noreply, ^state, [render?: false]} = App.handle_event(key("x"), state)
  end

  defp key(code), do: %Key{code: code, kind: "press"}

  defp state(identifiers) do
    snapshot =
      {:ok,
       %{
         running: Enum.map(identifiers, &%{identifier: &1}),
         retrying: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
       }}

    %State{
      snapshot: snapshot,
      selected_index: if(identifiers == [], do: nil, else: 0),
      snapshot_source: fn -> snapshot end,
      refresh_ms: 1_000
    }
  end
end
