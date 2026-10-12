defmodule Aiur.CapabilitiesSupervisionTest do
  use ExUnit.Case, async: true

  test "table and monitor retain dependency ordering in every run shape" do
    for interactive <- [false, true], headless <- [false, true], dashboard <- [false, true] do
      modules =
        Aiur.Application.child_specs(interactive_cli?: interactive, headless?: headless, dashboard?: dashboard, tailscale_funnel?: false)
        |> Enum.map(fn
          {module, _opts} -> module
          module when is_atom(module) -> module
          %{id: id} -> id
        end)

      assert Enum.at(modules, Enum.find_index(modules, &(&1 == Aiur.Webhooks.ModeTable)) + 1) == Aiur.Capabilities.Table
      assert Enum.at(modules, Enum.find_index(modules, &(&1 == Aiur.Events.Publisher)) + 1) == Aiur.Capabilities.Monitor
      assert Enum.find_index(modules, &(&1 == Task.Supervisor)) < Enum.find_index(modules, &(&1 == Aiur.Capabilities.Monitor))
    end
  end
end
