defmodule Aiur.AgentList.PrewarmRenderTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer

  defp render(state), do: state |> Renderer.render() |> IO.iodata_to_binary()

  test "shows the pre-warm loading line with the live phase when active and no agents yet" do
    out = render(%{summaries: [], prewarm_active?: true, prewarm_phase: :building, columns: 80, rows: 24})

    assert out =~ "Pre-warming base"
    assert out =~ "compiling"
    refute out =~ "(no agents running)"
  end

  test "tracks the phase label" do
    out = render(%{summaries: [], prewarm_active?: true, prewarm_phase: :cloning, columns: 80, rows: 24})
    assert out =~ "cloning"
  end

  test "shows the normal empty state when pre-warm is inactive" do
    out = render(%{summaries: [], prewarm_active?: false, columns: 80, rows: 24})

    assert out =~ "(no agents running)"
    refute out =~ "Pre-warming base"
  end
end
