defmodule Aiur.EngineCommand.UnitsTest do
  use ExUnit.Case, async: true
  import Aiur.EngineCommandTestSupport

  test "routes page-visible filters through the generic control RPC" do
    {out, 0} =
      run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\naiur_engine_main units --scope unfinished --condition queued,alert --json|)

    assert out =~
             "RPC:Aiur.AgentControlCLI.run_command(\"units\", Aiur.UnitsCLI, [scope: Base.decode64!(\"dW5maW5pc2hlZA==\"), conditions: [Base.decode64!(\"cXVldWVk\"), Base.decode64!(\"YWxlcnQ=\")], json: true])"
  end

  test "forwards human layout format and validates missing values" do
    {out, 0} =
      run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\naiur_engine_main units --format records|)

    assert out =~
             "RPC:Aiur.AgentControlCLI.run_command(\"units\", Aiur.UnitsCLI, [scope: Base.decode64!(\"bGl2ZQ==\"), format: Base.decode64!(\"cmVjb3Jkcw==\")])"

    {err, 64} = run_sourced_engine(~s|cmd_units --format|)
    assert err =~ "units --format requires a value"
  end
end
