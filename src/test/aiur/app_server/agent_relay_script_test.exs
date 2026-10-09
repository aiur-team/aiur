defmodule Aiur.AppServer.AgentRelayScriptTest do
  use ExUnit.Case, async: true

  @tag timeout: 60_000
  test "detached relay passes its socket, journal and process lifecycle contracts" do
    script = Path.expand("../../priv/agent_relay_test.py", __DIR__)
    {output, status} = System.cmd("python3", [script, "-v"], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "Ran 14 tests"
  end
end
