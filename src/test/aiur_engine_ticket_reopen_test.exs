defmodule AiurEngineTicketReopenTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.EngineCase

  test "reopen without --reason exits 64 with a usage message and no RPC" do
    for command <- ["reopen 12", "reopen 12 --reason '  '", "reopen 12 --reason", "reopen 0 --reason x", "reopen 12 --reason x --state done", "reopen 12 --reason x --oops"] do
      {output, code} = run_sourced_engine("run_control_rpc() { echo RPC; }; cmd_ticket #{command}", [])
      assert code == 64, command
      refute output =~ "RPC", command
    end

    {output, 64} = run_sourced_engine("cmd_ticket reopen 12", [])
    assert output =~ "requires --reason"
    assert output =~ "usage: aiur ticket reopen <id> --reason <text>"
  end

  test "reopen sends the reason and state across RPC as base64" do
    {rpc, 0} = run_sourced_engine(~S|USER=kevin; run_control_rpc() { echo "$1"; }; cmd_ticket reopen 12 --reason 'premise changed' --state rework --json|, [])

    assert rpc ==
             "Aiur.AgentControlCLI.ticket_reopen([id: 12, state: \"rework\", reason: Base.decode64!(\"#{Base.encode64("premise changed")}\"), by: Base.decode64!(\"#{Base.encode64("cli:kevin")}\"), json: true])\n"
  end
end
