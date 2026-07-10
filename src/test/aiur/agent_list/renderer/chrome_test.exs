defmodule Aiur.AgentList.Renderer.ChromeTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Chrome

  test "renders title and bottom chrome" do
    assert Chrome.title_row(80) |> IO.iodata_to_binary() =~ "╭─ AIUR"
    assert Chrome.bottom_border(80) |> IO.iodata_to_binary() =~ "newest"
  end
end
