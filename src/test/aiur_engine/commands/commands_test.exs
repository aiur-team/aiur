defmodule Aiur.EngineCommand.CommandsTest do
  use ExUnit.Case, async: true
  import Aiur.EngineCommandTestSupport

  test "routes filters and encoded detail arguments through the generic control RPC" do
    {out, 0} =
      run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\naiur_engine_main commands dec:42 --filter resolved --json --limit 10|)

    assert out =~
             "RPC:Aiur.AgentControlCLI.run_command(\"commands\", Aiur.CommandsCLI, [filter: :resolved, json: true, limit: 10, decision_id: Base.decode64!(\"ZGVjOjQy\")])"
  end

  test "reports missing option values as usage errors" do
    {out, 64} = run_sourced_engine(~s|cmd_commands --filter|)
    assert out =~ "commands --filter requires a value"
  end
end
