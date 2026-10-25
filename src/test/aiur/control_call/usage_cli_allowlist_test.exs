defmodule Aiur.ControlCall.UsageCliAllowlistTest do
  use ExUnit.Case, async: true

  alias Aiur.ControlCall

  test "allows the shared usage CLI and its one-release compatibility readers" do
    assert {:ok, %{module: Aiur.Usage.CLI, function: :rpc, args: [nil, false], scope: :read}} =
             ControlCall.parse("Aiur.Usage.CLI.rpc(nil, false)")

    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.Usage.CLI.rpc(\"codex\", true)")
    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.Usage.CLI.legacy_accounts(true, \"claude\")")
    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.Usage.CLI.legacy_ticket_usage(\"5692\", true)")
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

    assert {:error, :non_literal_argument} = ControlCall.parse("Aiur.Usage.CLI.legacy_ticket_usage(\"0\", true)")
  end
end
