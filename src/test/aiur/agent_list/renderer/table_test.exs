defmodule Aiur.AgentList.Renderer.TableTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.{Layout, Table}

  test "renders the empty table body" do
    output = Table.render_rows([], 0, :agents, 80, Layout.compute([], 80), %{}) |> IO.iodata_to_binary()
    assert output =~ "(no agents running)"
  end
end
