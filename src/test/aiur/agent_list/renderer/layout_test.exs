defmodule Aiur.AgentList.Renderer.LayoutTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Layout

  test "computes a responsive layout" do
    assert Layout.compute([%{identifier: "1", title: "A", model: "sonnet-4-6"}], 170).show_progress?
    assert Layout.min_id_width() == 4
    assert Layout.model_base_width() == 6
  end
end
