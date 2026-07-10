defmodule Aiur.AgentList.Renderer.CellsTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Cells

  test "formats runtime values" do
    assert Cells.format_runtime(-5) == "0:00"
    assert Cells.format_runtime(59) == "0:59"
    assert Cells.format_runtime(3599) == "59:59"
    assert Cells.format_runtime(3723) == "1:02:03"
    assert Cells.format_runtime(36_000) == "10h"
    assert Cells.format_runtime(:invalid) == "0:00"
  end
end
