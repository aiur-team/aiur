defmodule AiurEngineTicketEstimateTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.EngineCase

  test "estimate validates hours, reason, clear, actor and subcommand before RPC" do
    for command <- [
          "estimate 5 2.3 --reason x",
          "estimate 5 0 --reason x",
          "estimate 5 1000 --reason x",
          "estimate 5 abc --reason x",
          "estimate 5 7",
          "estimate 5 7 --reason '   '",
          "estimate 5 7 --reason $'line\\nbreak'",
          "estimate 5 --clear 3 --reason x",
          "estimate 5 --clear",
          "estimate 5 7 --reason x --by 'bad actor'",
          "frob",
          "estimate 0",
          "estimate abc",
          "estimate 5 --oops"
        ] do
      {output, code} = run_sourced_engine("run_control_rpc() { echo RPC; }; cmd_ticket #{command}", [])
      assert code == 64, command
      refute output =~ "RPC"
    end

    {output, 64} = run_sourced_engine("cmd_ticket estimate 5 2.3 --reason x", [])
    assert output =~ "multiple of 0.25"
  end

  test "estimate dispatches checked literals and encoded text for show, set and clear" do
    {show, 0} = run_sourced_engine(~S|run_control_rpc() { echo "$1"; }; cmd_ticket estimate 005 --json|, [])
    assert show == "Aiur.AgentControlCLI.ticket_estimate([id: 5, json: true])\n"
    {set, 0} = run_sourced_engine(~S|run_control_rpc() { echo "$1"; }; cmd_ticket estimate 5 7 --reason 'design rounds' --by cli:kevin|, [])
    assert set == "Aiur.AgentControlCLI.ticket_estimate([id: 5, hours: \"7\", reason: Base.decode64!(\"#{Base.encode64("design rounds")}\"), by: Base.decode64!(\"#{Base.encode64("cli:kevin")}\")])\n"
    {clear, 0} = run_sourced_engine(~S|run_control_rpc() { echo "$1"; }; cmd_ticket estimate 5 --clear --reason reset|, [])
    assert clear =~ "id: 5, clear: true, reason: Base.decode64!"
  end

  test "dev shim reaches the running daemon without rebuilding for ticket estimates" do
    source = File.read!(Path.expand("../../scripts/aiurdev", __DIR__))

    for {function, code} <- [{"targets_release_deliberately", 1}, {"pure_control_command", 0}] do
      [definition] = Regex.run(~r/^#{function}\(\) \{.*?^\}/ms, source)
      assert {"", ^code} = System.cmd("bash", ["-c", definition <> "\n#{function} ticket"], stderr_to_stdout: true)
    end
  end
end
