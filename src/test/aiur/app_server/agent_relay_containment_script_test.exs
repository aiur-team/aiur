defmodule Aiur.AppServer.AgentRelayContainmentScriptTest do
  use ExUnit.Case, async: true

  @tag timeout: 60_000
  test "a tool command that leaves the provider session dies when the provider ends or is stopped" do
    script = Path.expand("../../priv/agent_relay_containment_test.py", __DIR__)
    {output, status} = System.cmd("python3", [script, "-v"], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "Ran 4 tests"
  end
end
