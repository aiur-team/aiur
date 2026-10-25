defmodule Aiur.ControlCall.UsageCliAllowlistTest do
  use ExUnit.Case, async: true

  alias Aiur.ControlCall

  test "allows only the shared usage CLI read call" do
    assert {:ok, %{module: Aiur.Usage.CLI, function: :rpc, args: [nil, false], scope: :read}} =
             ControlCall.parse("Aiur.Usage.CLI.rpc(nil, false)")

    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.Usage.CLI.rpc(\"codex\", true)")
    assert {:error, :non_literal_argument} = ControlCall.parse("Aiur.Usage.CLI.rpc(:codex, true)")

    for expression <- [
          "Aiur.AgentControlCLI.usage()",
          "Aiur.AgentControlCLI.accounts(true)",
          "Aiur.AgentControlCLI.github_cost()",
          "Aiur.AgentControlCLI.github_usage()",
          "Aiur.TicketUsageCLI.rpc(\"5692\", [])"
        ] do
      assert {:error, :denied_remote} = ControlCall.parse(expression), expression
    end
  end
end
