defmodule AiurCapabilitiesEngineTest do
  use ExUnit.Case, async: true
  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)
  @shim Path.expand("../../scripts/aiurdev", __DIR__)

  defp run_engine(args) do
    System.cmd("bash", ["-c", "source \"$AIUR_ENGINE\"; run_control_rpc() { echo \"RPC:$1\"; }; aiur_engine_main \"$@\"", "capabilities-test" | args],
      env: [{"AIUR_ENGINE", @engine}, {"AIUR_RELEASE_NODE", "aiur-capabilities-test@127.0.0.1"}],
      stderr_to_stdout: true
    )
  end

  test "dispatches plain and JSON reports through the control RPC" do
    assert {"RPC:Aiur.AgentControlCLI.capabilities([])\n", 0} = run_engine(["capabilities"])
    assert {"RPC:Aiur.AgentControlCLI.capabilities([json: true])\n", 0} = run_engine(["capabilities", "--json"])
  end

  test "rejects unknown flags and positional arguments" do
    assert {"aiur: capabilities received an unknown option: --bogus\n", 64} = run_engine(["capabilities", "--bogus"])
    assert {"aiur: capabilities does not accept positional arguments\n", 64} = run_engine(["capabilities", "extra"])
  end

  test "dev shim treats capabilities as a non-building control command" do
    shim = File.read!(@shim)

    for {function, code} <- [{"targets_release_deliberately", 1}, {"pure_control_command", 0}] do
      [definition] = Regex.run(~r/^#{function}\(\) \{.*?^\}/ms, shim)
      assert {"", ^code} = System.cmd("bash", ["-c", definition <> "\n#{function} capabilities"])
    end
  end
end
