defmodule Aiur.AgentList.Renderer.CellsTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Cells

  test "formats runtime values" do
    assert Cells.format_runtime(-5) == "0:00"
    assert Cells.format_runtime(3723) == "1:02:03"
  end
end
