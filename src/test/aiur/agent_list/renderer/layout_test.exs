defmodule Aiur.AgentList.Renderer.LayoutTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Layout

  test "computes a responsive layout" do
    wide = Layout.compute([%{identifier: "1", title: "A", model: "sonnet-4-6"}], 170)
    narrow = Layout.compute([%{identifier: "long-identifier", title: "A", model: "sonnet-4-6"}], 40)
    assert wide.show_progress?
    assert wide.model_width >= String.length("Claude Sonnet 4.6")
    refute narrow.show_progress?
    assert narrow.id_width >= Layout.min_id_width()
    assert Layout.min_id_width() == 4
    assert Layout.model_base_width() == 6
    assert {Layout.state_cell_width(), Layout.attention_cell_width(), Layout.rc_cell_width()} == {3, 4, 3}
    assert {Layout.progress_bar_width(), Layout.runtime_cell_width(), Layout.max_latest_width()} == {10, 7, 60}
  end
end
