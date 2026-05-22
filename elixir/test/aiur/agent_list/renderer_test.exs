defmodule Aiur.AgentList.RendererTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer

  defp render(state), do: IO.iodata_to_binary(Renderer.render(state))

  defp visible(text), do: Regex.replace(~r/\e\[[?0-9;]*[A-Za-z]/, text, "")

  defp row_for(output, identifier) do
    output
    |> String.split(["\r\n", "\n"])
    |> Enum.find(fn line -> line =~ identifier end)
  end

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

  test "renders the bordered AIUR STATUS title" do
    out = render(base_state()) |> visible()

    assert out =~ "╭─ AIUR STATUS"
    assert out =~ "╰"
  end

  test "renders the metadata block with project, dashboard, and refresh chip" do
    out =
      render(
        base_state(%{
          project_label: "applekid/aiur",
          dashboard_url: "http://127.0.0.1:4000/",
          refresh_label: "15s"
        })
      )
      |> visible()

    assert out =~ "Project:"
    assert out =~ "applekid/aiur"
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
    assert out =~ "🔄 in 0s"
    refute out =~ "🔄 n/a"
  end

  test "renders empty refresh labels as in 0s" do
    out = render(base_state(%{refresh_label: ""})) |> visible()

    assert out =~ "🔄 in 0s"
    refute out =~ "🔄 n/a"
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

  test "focused max display highlights editable value and shows arrow affordances" do
    out =
      render(
        base_state(%{
          agent_kind: "codex",
          agent_count: 1,
          max_agents: 2,
          selection_focus: :max_agents
        })
      )
      |> visible()

    assert out =~ "codex (1/[2])"
    assert out =~ "← →"
  end

  test "max alert applies terminal highlight styling" do
    raw =
      render(
        base_state(%{
          agent_kind: "codex",
          agent_count: 2,
          max_agents: 2,
          max_agents_alert?: true
        })
      )

    assert raw =~ IO.ANSI.red()
    assert raw =~ IO.ANSI.reverse()
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

  test "does not mark an agent row when the max control is focused" do
    summaries = [
      %{identifier: "MT-1", status: :running, alert_count: 0}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          selection_index: 0,
          selection_focus: :max_agents,
          agent_kind: "codex",
          agent_count: 1,
          max_agents: 2
        })
      )
      |> visible()

    assert out =~ "codex (1/[2])"
    refute out =~ "▶ MT-1"
  end

  test "renders paused agents with a pause emoji" do
    summaries = [
      %{
        identifier: "MT-9",
        status: :running,
        alert_count: 0,
        work_state: :paused
      }
    ]

    out = render(base_state(%{summaries: summaries})) |> visible()

    assert out =~ "⏸️"
  end

  test "running agents without phase activity render idle" do
    summaries = [
      %{
        identifier: "MT-WORK",
        status: :running,
        alert_count: 0,
        tag: "agent:todo",
        work_state: :working
      }
    ]

    out = render(base_state(%{summaries: summaries})) |> visible()

    assert row_for(out, "MT-WORK") =~ "⚫"
    refute out =~ "🟡"
    refute out =~ "🟢"
  end

  test "running agents render phase-specific status emoji" do
    summaries = [
      %{identifier: "MT-BRAIN", status: :running, alert_count: 0},
      %{identifier: "MT-PLAN", status: :running, alert_count: 0},
      %{identifier: "MT-WORK", status: :running, alert_count: 0},
      %{identifier: "MT-REVIEW", status: :running, alert_count: 0}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          phase_by_identifier: %{
            "MT-BRAIN" => :brainstorm,
            "MT-PLAN" => :plan,
            "MT-WORK" => :work,
            "MT-REVIEW" => :review
          }
        })
      )
      |> visible()

    assert row_for(out, "MT-BRAIN") =~ "🧠"
    assert row_for(out, "MT-PLAN") =~ "📋"
    assert row_for(out, "MT-WORK") =~ "🛠️"
    assert row_for(out, "MT-REVIEW") =~ "🔍"
  end

  test "running agents render derived activity emoji ahead of phase" do
    summaries = [
      %{identifier: "MT-TEST", status: :running, alert_count: 0},
      %{identifier: "MT-DEBUG", status: :running, alert_count: 0},
      %{identifier: "MT-PR", status: :running, alert_count: 0},
      %{identifier: "MT-RESTART", status: :running, alert_count: 0}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          phase_by_identifier: %{
            "MT-TEST" => :work,
            "MT-DEBUG" => :work,
            "MT-PR" => :review,
            "MT-RESTART" => :work
          },
          activity_by_identifier: %{
            "MT-TEST" => :test,
            "MT-DEBUG" => :debug,
            "MT-PR" => :pr_opened,
            "MT-RESTART" => :restarted
          }
        })
      )
      |> visible()

    assert row_for(out, "MT-TEST") =~ "🧪"
    assert row_for(out, "MT-DEBUG") =~ "🐛"
    assert row_for(out, "MT-PR") =~ "🚀"
    assert row_for(out, "MT-RESTART") =~ "🔁"
  end

  test "warming identifiers render hourglass ahead of active phase" do
    summaries = [%{identifier: "MT-WARMING", status: :running, alert_count: 0}]

    out =
      render(
        base_state(%{
          summaries: summaries,
          warming_identifiers: MapSet.new(["MT-WARMING"]),
          phase_by_identifier: %{"MT-WARMING" => :work}
        })
      )
      |> visible()

    assert row_for(out, "MT-WARMING") =~ "⏳"
    refute row_for(out, "MT-WARMING") =~ "🛠️"
  end

  test "terminal and operator states take precedence over phases" do
    summaries = [
      %{identifier: "MT-PAUSED", status: :running, alert_count: 0, work_state: :paused},
      %{identifier: "MT-ERROR", status: :running, alert_count: 0, work_state: :error},
      %{identifier: "MT-DONE", status: :done, alert_count: 0}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          phase_by_identifier: %{
            "MT-PAUSED" => :work,
            "MT-ERROR" => :work,
            "MT-DONE" => :work
          }
        })
      )
      |> visible()

    assert row_for(out, "MT-PAUSED") =~ "⏸️"
    assert row_for(out, "MT-ERROR") =~ "⚠️"
    assert row_for(out, "MT-DONE") =~ "🏁"
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
    # `\e[2J` is full-screen clear (causes flicker); `\e[J` is
    # clear-from-cursor-to-end (no flicker). We use the latter.
    refute raw =~ "\e[2J"
    assert raw =~ "\e[H"
  end

  test "clears every row below the last rendered content (no stale-footer bug)" do
    # A frame that renders fewer rows must leave the rows below it
    # blank. We assert the trailing escape sequence positions the
    # cursor exactly one row below the last content row and emits
    # `\e[J` to clear the rest of the screen.
    raw = render(base_state(%{rows: 30}))

    # Cursor home at the start.
    assert raw =~ "\e[H"
    # Some `\e[<N>;1H` cursor reset followed by `\e[J` clear-to-end.
    assert raw =~ ~r/\e\[\d+;1H\e\[J/
  end

  test "renders the open-pane circle next to ids that have a live pane" do
    summaries = [
      %{identifier: "MT-1", status: :running, alert_count: 0},
      %{identifier: "MT-2", status: :running, alert_count: 0}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          visible_sessions: %{1 => "MT-1"}
        })
      )
      |> visible()

    # MT-1 line carries the circle, MT-2 line does not.
    lines = String.split(out, ["\r\n", "\n"])

    mt1_line = Enum.find(lines, fn line -> line =~ "MT-1" end)
    mt2_line = Enum.find(lines, fn line -> line =~ "MT-2" end)

    assert mt1_line =~ "●"
    refute mt2_line =~ "●"
  end

  test "open-pane circle defaults off when no visible_sessions are passed" do
    summaries = [%{identifier: "MT-X", status: :running, alert_count: 0}]
    out = render(base_state(%{summaries: summaries})) |> visible()

    refute out =~ "●"
  end

  test "footer shows v layout inline when terminal is wide enough" do
    out = render(base_state(%{columns: 100})) |> visible()

    assert out =~ "v layout"
    assert out =~ "? help"
    # All keybinds live on a single row when width allows.
    assert out =~ ~r/v layout\s+\? help\s+q quit/
  end

  test "footer wraps v layout to a second row when width is tight" do
    # 70-col terminal fits the original keybinds but not the version
    # that also includes "v layout". The primary row keeps the original
    # keybinds; "v layout" wraps below.
    out = render(base_state(%{columns: 70})) |> visible()
    lines = String.split(out, ["\r\n", "\n"])

    primary_index =
      Enum.find_index(lines, fn line ->
        line =~ "↑/↓ select" and line =~ "? help"
      end)

    assert primary_index, "expected primary keybind row to render"
    secondary = Enum.at(lines, primary_index + 1) || ""
    assert secondary =~ "v layout"
    refute Enum.at(lines, primary_index) =~ "v layout"
  end

  test "help overlay documents the v layout keybind" do
    out =
      render(base_state(%{help_visible?: true, columns: 100}))
      |> visible()

    assert out =~ "v"
    assert out =~ "toggle pane layout"
  end

  test "help overlay documents the phase status palette" do
    out =
      render(base_state(%{help_visible?: true, columns: 100, rows: 40}))
      |> visible()

    for glyph <- ["⏳", "🧠", "📋", "🛠️", "🧪", "🔍", "🐛", "🚀", "🔁", "⏸️", "⚠️", "🏁", "⚫"] do
      assert out =~ glyph
    end
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
