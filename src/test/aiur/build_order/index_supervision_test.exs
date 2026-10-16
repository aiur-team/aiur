defmodule Aiur.BuildOrder.IndexSupervisionTest do
  use ExUnit.Case, async: false
  use Aiur.TestSupport

  test "index is last after every interactive child and absent without dashboard" do
    children = Aiur.Application.child_specs(interactive_cli?: true, headless?: false, dashboard?: true)

    modules =
      Enum.map(children, fn
        {module, _} -> module
        module -> module
      end)

    assert List.last(modules) == AiurWeb.Build.Index
    assert Aiur.Tmux in modules
    without = Aiur.Application.child_specs(interactive_cli?: true, headless?: false, dashboard?: false)
    refute Enum.any?(without, &(&1 == AiurWeb.Build.Index))
  end
end
