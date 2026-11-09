defmodule AiurEngineHistoryLabelWritesTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.EngineCase
  @stub ~s|run_control_rpc() { echo "RPC=$1"; }\n|

  test "dispatcher routes each whitelisted action and checked integer literals" do
    {out, 0} = run_sourced_engine(@stub <> "aiur_engine_main history label-writes start --expect 007 --per-hour 3 --epic-labels --json", [{"AIUR_AGENT_WORKSPACE", ""}])
    assert out =~ "RPC=Aiur.AgentControlCLI.history_label_writes([action: :start, json: true, epic_labels: true, per_hour: 3, expect: 7])"

    [_, expression] = Regex.run(~r/RPC=(.+)/, out)
    assert Aiur.ControlCall.parse(expression) == {:error, :denied_remote}

    for action <- ["plan", "pause", "resume", "status"] do
      {out, 0} = run_sourced_engine(@stub <> "cmd_history label-writes #{action}", [{"AIUR_AGENT_WORKSPACE", ""}])
      assert out =~ "RPC=Aiur.AgentControlCLI.history_label_writes([action: :#{action},"
      [_, expression] = Regex.run(~r/RPC=(.+)/, out)

      case action do
        "resume" -> assert Aiur.ControlCall.parse(expression) == {:error, :denied_remote}
        "pause" -> assert {:ok, %{scope: :write}} = Aiur.ControlCall.parse(expression)
        _ -> assert {:ok, %{scope: :read}} = Aiur.ControlCall.parse(expression)
      end
    end
  end

  test "invalid input stops before control rpc" do
    for argv <- [
          "",
          "frob",
          "start",
          "start --expect 1x",
          "start --expect -1",
          "start --expect 1 --per-hour -3",
          "start --expect 1 --per-hour",
          "start --expect 1 --per-hour 12345678901",
          "start --expect 12345678901",
          "start --expect",
          "start --what",
          "status --expect 1",
          "pause --epic-labels",
          "plan --per-hour 2"
        ] do
      {out, status} = run_sourced_engine(@stub <> "cmd_history label-writes #{argv}", [{"AIUR_AGENT_WORKSPACE", ""}])
      assert status == 64, "#{argv}: #{out}"
      refute out =~ "RPC="
    end
  end

  test "agent workspaces refuse start and resume but can inspect and stop" do
    for action <- ["start --expect 1", "resume"] do
      {out, 1} = run_sourced_engine(@stub <> "cmd_history label-writes #{action}", [{"AIUR_AGENT_WORKSPACE", "/w"}])
      assert out =~ "history label-writes is refused inside agent workspaces"
      refute out =~ "RPC="
    end

    for action <- ["plan", "status", "pause"] do
      {out, 0} = run_sourced_engine(@stub <> "cmd_history label-writes #{action}", [{"AIUR_AGENT_WORKSPACE", "/w"}])
      assert out =~ "RPC="
    end
  end
end
