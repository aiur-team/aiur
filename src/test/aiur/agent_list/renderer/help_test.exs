defmodule Aiur.AgentList.Renderer.HelpTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Help

  test "renders the help overlay" do
    {iodata, count} = Help.render(120)
    assert IO.iodata_to_binary(iodata) =~ "Keybinds"
    assert count > 4
  end
end
