defmodule Aiur.CLIReferenceTest do
  use ExUnit.Case, async: true

  alias Aiur.CLI

  test "reference rows expose parser types and adjacent descriptions" do
    options = CLI.reference_options()

    assert Enum.find(options, &(&1.name == :max_agents)) == %{
             name: :max_agents,
             type: :integer,
             syntax: "aiur --max-agents 6",
             description: "Launch-only session cap. It wins over `agent.max_concurrent_agents`; Aiur warns when it exceeds that setting. `status` identifies the active binding.",
             example: "aiur --max-agents 6"
           }

    assert Enum.any?(options, &(&1.name == :i_understand_that_this_will_be_running_without_the_usual_guardrails and &1.type == :boolean))
    refute Enum.any?(options, &(&1.name == :bg))
  end
end
