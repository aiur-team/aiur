defmodule Aiur.AgentList.Renderer.TableTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.{Layout, Table}

  test "renders the empty table body" do
    output = Table.render_rows([], 0, :agents, 80, Layout.compute([], 80), %{}) |> IO.iodata_to_binary()
    assert output =~ "(no agents running)"
    prewarm = Map.merge(Layout.compute([], 80), %{prewarm_active?: true, prewarm_phase: :fetching, now_ms: 0})
    assert Table.render_rows([], 0, :agents, 80, prewarm, %{}) |> IO.iodata_to_binary() =~ "Pre-warming base (fetching main)"
  end
end
