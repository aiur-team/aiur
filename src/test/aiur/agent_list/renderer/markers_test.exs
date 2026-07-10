defmodule Aiur.AgentList.Renderer.MarkersTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Markers

  test "applies marker precedence and phase glyphs" do
    assert Markers.marker_for_identifier("1", MapSet.new(["1"]), %{}, MapSet.new()) == "🟢"
    assert Markers.marker_for_identifier("1", MapSet.new(), %{"1" => %{visible_in: 0}}, MapSet.new(["1"])) == "⚪"
    assert Markers.marker_for_identifier("1", MapSet.new(), %{"1" => %{visible_in: 0}}, MapSet.new()) == "🔘"
    assert Markers.marker_for_identifier("1", MapSet.new(), %{}, MapSet.new()) == "⏳"
    assert Markers.finished_work_state?(:deactivated)
    assert Markers.phase_emoji(:work) == "🔨"
  end
end
