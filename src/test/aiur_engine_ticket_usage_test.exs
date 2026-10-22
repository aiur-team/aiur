defmodule AiurEngineTicketUsageTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "ticket-usage routes the ticket and --json through the control rpc" do
    {out, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_ticket_usage 5692 --json|, [])
    assert out =~ ~s|RPC:Aiur.TicketUsageCLI.rpc("5692", [json: true])|
  end

  test "ticket-usage defaults to the plain report" do
    {out, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_ticket_usage 5692|, [])
    assert out =~ ~s|RPC:Aiur.TicketUsageCLI.rpc("5692", [])|
  end

  # The ticket is interpolated into an Elixir expression, so anything but
  # digits must stop in the launcher before it can reach the RPC.
  test "ticket-usage rejects malformed arguments before an RPC" do
    for {argv, message} <- [
          {"", "ticket-usage requires a ticket number"},
          {~s|'1"); System.halt(0); ("'|, "ticket-usage expects a numeric ticket ID"},
          {"MT-1", "ticket-usage expects a numeric ticket ID"},
          {"1 2", "ticket-usage accepts one ticket"},
          {"--unknown", "ticket-usage received an unknown option"}
        ] do
      {out, 64} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_ticket_usage #{argv}|, [])
      assert out =~ message
      refute out =~ "RPC:"
    end
  end
end
