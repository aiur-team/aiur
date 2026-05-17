defmodule SymphonyElixir.AgentList.RendererTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentList.Renderer

  test "render/4 returns iodata for an empty summary list" do
    iodata = Renderer.render([], 80, 24, 0)
    assert IO.iodata_to_binary(iodata) == ""
  end

  test "render/4 returns iodata for a populated summary list (scaffold)" do
    summaries = [%{identifier: "MT-1", status: :running, alert_count: 0}]
    assert is_list(Renderer.render(summaries, 80, 24, 0))
  end
end
