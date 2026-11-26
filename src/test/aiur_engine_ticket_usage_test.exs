defmodule AiurEngineTicketUsageTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "ticket-usage forwards the legacy ticket argument through the original CLI reader" do
    {out, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\nusage_alias ticket-usage 5692 --json|, [])
    assert out =~ "deprecated; use 'aiur usage ticket'"
    assert out =~ ~s|RPC:Aiur.TicketUsageCLI.rpc(Base.decode64!("NTY5Mg=="), json: true)|
  end

  test "ticket-usage rejects malformed legacy arguments before an RPC" do
    for {argv, message} <- [
          {"", "ticket-usage requires a numeric ticket id"},
          {~s|'1"); System.halt(0); ("'|, "ticket-usage requires a numeric ticket id"},
          {"MT-1", "ticket-usage requires a numeric ticket id"},
          {"1 2", "ticket-usage accepts at most one positional argument"},
          {"--unknown", "ticket-usage does not accept --unknown"}
        ] do
      {out, 1} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\nusage_alias ticket-usage #{argv}|, [])
      assert out =~ message
      refute out =~ "RPC:"
    end
  end
end
