defmodule Aiur.AgentList.Renderer.CellsTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.{Cells, Layout}

  test "formats runtime values" do
    assert Cells.format_runtime(-5) == "0:00"
    assert Cells.format_runtime(59) == "0:59"
    assert Cells.format_runtime(3599) == "59:59"
    assert Cells.format_runtime(3723) == "1:02:03"
    assert Cells.format_runtime(36_000) == "10h"
    assert Cells.format_runtime(:invalid) == "0:00"
  end

  test "uses dotted progress and suppresses finished placeholders" do
    layout = Map.merge(Layout.compute([], 80), %{progress_by_id: %{"1" => []}, now_ms: 0, attach_state: %{}, agents_with_content: MapSet.new()})

    assert Cells.progress_cell("1", layout) == "··········"
    assert Cells.phase_placeholder("1", layout, %{work_state: :deactivated}) == ""
    assert Cells.phase_placeholder("1", layout, %{status: :queued}) =~ "Queueing agent…"
    assert Cells.spinner_frame(layout) == Cells.spinner_frame(layout)
  end
end
