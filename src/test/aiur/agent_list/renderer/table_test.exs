defmodule Aiur.AgentList.Renderer.TableTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.{Layout, Table}

  test "renders the empty table body" do
    output = Table.render_rows([], 0, :agents, 80, Layout.compute([], 80), %{}) |> IO.iodata_to_binary()
    assert output =~ "(no agents running)"
    prewarm = Map.merge(Layout.compute([], 80), %{prewarm_active?: true, prewarm_phase: :fetching, now_ms: 0})
    assert Table.render_rows([], 0, :agents, 80, prewarm, %{}) |> IO.iodata_to_binary() =~ "Pre-warming base (fetching main)"
  end

  test "keeps selected links while stripping interior colors" do
    summary = %{identifier: "1", title: "Working", status: :running}

    layout =
      Map.merge(Layout.compute([summary], 120), %{
        project_label: "aiur-team/aiur",
        phase_by_identifier: %{},
        open_attentions_by_id: %{},
        latest_event_by_id: %{},
        attach_state: %{},
        agents_with_content: MapSet.new(),
        progress_by_id: %{},
        now_ms: 0,
        truecolor?: true
      })

    selected = Table.render_row(summary, true, 120, layout, %{"1" => "⚪"}) |> IO.iodata_to_binary()
    unselected = Table.render_row(summary, false, 120, layout, %{"1" => "⚪"}) |> IO.iodata_to_binary()

    assert selected =~ IO.ANSI.reverse()
    assert selected =~ "\e]8;;https://github.com/aiur-team/aiur/issues/1"
    assert unselected =~ "│" <> IO.ANSI.reset()
  end
end
