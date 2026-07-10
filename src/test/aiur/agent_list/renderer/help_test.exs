defmodule Aiur.AgentList.Renderer.HelpTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentList.Renderer.Help

  test "renders the help overlay" do
    {iodata, count} = Help.render(120)
    assert IO.iodata_to_binary(iodata) =~ "Keybinds"
    assert IO.iodata_to_binary(iodata) =~ "State circle"
    assert count == 4 + length(Help.help_body_rows(120))
  end
end
