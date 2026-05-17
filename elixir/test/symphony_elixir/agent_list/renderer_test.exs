defmodule SymphonyElixir.AgentList.RendererTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentList.Renderer

  defp render(state), do: IO.iodata_to_binary(Renderer.render(state))

  test "renders an empty list with a placeholder line" do
    output = render(%{summaries: [], selection_index: 0, columns: 40, rows: 10})

    assert output =~ "Symphony — Agents"
    assert output =~ "(no agents running)"
  end

  test "renders one agent per row and marks the selected row" do
    summaries = [
      %{identifier: "MT-1", status: :running, alert_count: 0},
      %{identifier: "MT-2", status: :running, alert_count: 0}
    ]

    output = render(%{summaries: summaries, selection_index: 1, columns: 60, rows: 10})

    assert output =~ "  MT-1"
    assert output =~ "▶ MT-2"
  end

  test "shows alert count when greater than zero" do
    summaries = [%{identifier: "MT-3", status: :running, alert_count: 5}]
    output = render(%{summaries: summaries, selection_index: 0, columns: 60, rows: 10})

    assert output =~ "MT-3"
    assert output =~ "(5)"
  end

  test "truncates rows that exceed the terminal width" do
    long_id = String.duplicate("X", 200)
    summaries = [%{identifier: long_id, status: :running, alert_count: 0}]

    output = render(%{summaries: summaries, selection_index: 0, columns: 20, rows: 10})

    # Visible width per line (after stripping ANSI escapes) should never
    # exceed (columns - 1). The renderer reserves the final column.
    output
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&Regex.replace(~r/\e\[[0-9;]*[A-Za-z]/, &1, ""))
    |> Enum.each(fn line -> assert String.length(line) <= 19, "line too long: #{inspect(line)}" end)
  end
end
