defmodule Aiur.AppServer.AgentRelayIOScriptTest do
  use ExUnit.Case, async: true

  @tag timeout: 60_000
  test "relay filesystem failures stop providers and diagnostic logs stay bounded" do
    script = Path.expand("../../priv/agent_relay_io_test.py", __DIR__)
    {output, status} = System.cmd("python3", [script, "-v"], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "Ran 3 tests"
  end
end
