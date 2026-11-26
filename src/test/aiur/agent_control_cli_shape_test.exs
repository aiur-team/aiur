defmodule Aiur.AgentControlCLIShapeTest do
  use ExUnit.Case, async: true

  test "AgentControlCLI defines only delegates and the module doc" do
    path = Path.expand("../../lib/aiur/agent_control_cli.ex", __DIR__)
    source = File.read!(path)
    assert length(String.split(source, "\n")) < 200
    assert {:defmodule, _, [_, [do: {:__block__, _, declarations}]]} = Code.string_to_quoted!(source)

    assert Enum.all?(declarations, fn
             {:@, _, [{:moduledoc, _, [false]}]} -> true
             {:@, _, [{:spec, _, _}]} -> true
             {:alias, _, [{:__aliases__, _, [:Aiur, :Application, :StartupChecks]}]} -> true
             {:alias, _, [{:__aliases__, _, [:Aiur, :Orchestrator, :StatusCLI]}]} -> true
             {:defdelegate, _, _} -> true
             {:def, _, [{:status, _, _}, [do: _]]} -> true
             _ -> false
           end)
  end
end
