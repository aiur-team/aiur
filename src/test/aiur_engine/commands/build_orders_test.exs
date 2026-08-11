defmodule Aiur.EngineCommand.BuildOrdersTest do
  use ExUnit.Case, async: true
  import Aiur.EngineCommandTestSupport

  test "routes its selector and JSON mode through the generic control RPC" do
    {out, 0} =
      run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\naiur_engine_main build-orders 1363 --json|)

    assert out =~
             "RPC:Aiur.AgentControlCLI.run_command(\"build-orders\", Aiur.BuildOrdersCLI, [json: true, root: Base.decode64!(\"MTM2Mw==\")])"
  end

  test "rejects multiple roots" do
    {out, 64} = run_sourced_engine(~s|cmd_build_orders 1363 1467|)
    assert out =~ "build-orders accepts at most one root"
  end
end
