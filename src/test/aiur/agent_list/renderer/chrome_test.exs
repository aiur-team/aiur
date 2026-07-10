defmodule Aiur.AgentList.Renderer.ChromeTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Chrome

  test "renders title and bottom chrome" do
    assert Chrome.title_row(80) |> IO.iodata_to_binary() =~ "╭─ AIUR"
    assert Chrome.bottom_border(80) |> IO.iodata_to_binary() =~ "newest"
    assert Chrome.bottom_border(10) |> IO.iodata_to_binary() =~ "╰"
    assert Chrome.footer_split(120, nil).line_count == 1
    assert Chrome.footer_split(60, nil).line_count == 2
    focused = Chrome.agents_row_iolist("agents", 3, 2, true, true, 120) |> IO.iodata_to_binary()
    assert focused =~ "[2]"
    assert focused =~ " drain"
    assert focused =~ "← →"
  end
end
