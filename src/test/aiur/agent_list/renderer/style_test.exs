defmodule Aiur.AgentList.Renderer.StyleTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer.Style

  test "palette functions return the exact IO.ANSI counterparts" do
    assert Style.reset() == IO.ANSI.reset()
    assert Style.bold() == IO.ANSI.bright()
    assert Style.dim() == IO.ANSI.faint()
    assert Style.cyan() == IO.ANSI.cyan()
    assert Style.gray() == IO.ANSI.light_black()
    assert Style.green() == IO.ANSI.green()
    assert Style.red() == IO.ANSI.red()
    assert Style.reverse() == IO.ANSI.reverse()
    assert Style.magenta() == IO.ANSI.magenta()
    assert Style.blue() == IO.ANSI.blue()
  end
end
