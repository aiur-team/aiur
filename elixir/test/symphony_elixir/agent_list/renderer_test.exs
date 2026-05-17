defmodule SymphonyElixir.AgentList.RendererTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentList.Renderer

  defp render(state), do: IO.iodata_to_binary(Renderer.render(state))

  defp visible(text), do: Regex.replace(~r/\e\[[0-9;]*[A-Za-z]/, text, "")

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        summaries: [],
        selection_index: 0,
        columns: 60,
        rows: 20,
        project_label: nil,
        dashboard_url: nil,
        refresh_label: nil,
        agent_kind: nil,
        agent_count: nil,
        max_agents: nil
      },
      overrides
    )
  end

  test "renders the bordered SYMPHONY STATUS title" do
    out = render(base_state()) |> visible()

    assert out =~ "╭─ SYMPHONY STATUS"
    assert out =~ "╰"
  end

  test "renders the metadata block with project, dashboard, and refresh chip" do
    out =
      render(
        base_state(%{
          project_label: "applekid/symphony",
          dashboard_url: "http://127.0.0.1:4000/",
          refresh_label: "15s"
        })
      )
      |> visible()

    assert out =~ "Project:"
    assert out =~ "applekid/symphony"
    assert out =~ "Dashboard:"
    assert out =~ "http://127.0.0.1:4000/"
    # Refresh now lives in the title row as a 🔄 chip on the right.
    assert out =~ "🔄 in 15s"
  end

  test "falls back to n/a placeholders when metadata is missing" do
    out = render(base_state()) |> visible()

    assert out =~ "Agents: n/a"
    assert out =~ "Project: n/a"
    assert out =~ "Dashboard: n/a"
    assert out =~ "🔄 n/a"
  end

  test "shows agent count and max in the Agents row" do
    out =
      render(
        base_state(%{
          summaries: [
            %{identifier: "MT-1", status: :running, alert_count: 0},
            %{identifier: "MT-2", status: :running, alert_count: 0}
          ],
          agent_kind: "claude",
          agent_count: 2,
          max_agents: 5
        })
      )
      |> visible()

    assert out =~ "Agents:"
    assert out =~ "claude (2/5)"
  end

  test "renders the agent table header columns" do
    out =
      render(base_state(%{summaries: [%{identifier: "MT-1", status: :running, alert_count: 0}]}))
      |> visible()

    # ID and AGE are labelled; TAG and STATE columns use emoji-only
    # cells and therefore have no header text. Column order is
    # ID → AGE → tag-circle → state-circle → TITLE.
    assert out =~ ~r/ID\s+AGE\s+TITLE/
  end

  test "shows '(no agents running)' when the list is empty" do
    out = render(base_state()) |> visible()
    assert out =~ "(no agents running)"
  end

  test "renders one agent per row and marks the selected row" do
    summaries = [
      %{identifier: "MT-1", status: :running, alert_count: 0},
      %{identifier: "MT-2", status: :running, alert_count: 0}
    ]

    out = render(base_state(%{summaries: summaries, selection_index: 1})) |> visible()

    assert out =~ "  MT-1"
    assert out =~ "▶ MT-2"
  end

  test "renders state with a colored circle emoji" do
    summaries = [
      %{
        identifier: "MT-9",
        status: :running,
        alert_count: 0,
        work_state: :paused
      }
    ]

    out = render(base_state(%{summaries: summaries})) |> visible()

    # Paused agent state surfaces as a yellow circle (🟡 in the state
    # column). Working agents would render as 🟢.
    assert out =~ "🟡"
  end

  test "renders an age column from runtime_seconds and turn_count" do
    summaries = [
      %{
        identifier: "MT-A",
        status: :running,
        alert_count: 0,
        runtime_seconds: 125,
        turn_count: 3
      }
    ]

    out = render(base_state(%{summaries: summaries})) |> visible()

    assert out =~ "2m/3t"
  end

  test "title column flexes to fill the remaining width" do
    summaries = [
      %{
        identifier: "MT-A",
        status: :running,
        alert_count: 0,
        title: "A short title"
      }
    ]

    out = render(base_state(%{summaries: summaries, columns: 80})) |> visible()
    assert out =~ "A short title"
  end

  test "skips the screen clear escape so frames do not flash" do
    raw = render(base_state())
    refute raw =~ "\e[2J"
    assert raw =~ "\e[H"
  end

  test "reserves the final terminal column to avoid autowrap" do
    long_id = String.duplicate("X", 200)
    summaries = [%{identifier: long_id, status: :running, alert_count: 0}]

    raw = render(base_state(%{summaries: summaries, columns: 30}))

    raw
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&visible/1)
    |> Enum.each(fn line ->
      assert String.length(line) <= 29, "line too long: #{inspect(line)}"
    end)
  end
end
