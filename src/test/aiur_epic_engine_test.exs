defmodule Aiur.EpicEngineTest do
  use ExUnit.Case, async: true
  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)
  defp shell(command, env \\ []) do
    System.cmd(
      "bash",
      [
        "-c",
        ~S|source "$1"; run_control_rpc() { printf '%s\n' "$1"; }; | <> command,
        "epic-test",
        @engine
      ],
      env: env,
      stderr_to_stdout: true
    )
  end

  test "V-25 batch command encodes actor and epic and normalizes hash ids" do
    assert shell("cmd_epic set bugs 12 '#13' --as kevin --json") ==
             {"Aiur.AgentControlCLI.epic([action: :set, epic: Base.decode64!(\"YnVncw==\"), ids: [12, 13], who: Base.decode64!(\"a2V2aW4=\"), source: :cli, json: true])\n", 0}

    assert {text, 0} = shell("cmd_epic set bugs 12 --as kevin --source backfill-agent")
    assert text =~ "source: :\"backfill-agent\""
    assert {text, 0} = shell("cmd_epic clear '#12' --as kevin --json")
    assert text =~ "action: :clear, ids: [12]"

    assert shell("cmd_epic show 12 --json") ==
             {"Aiur.AgentControlCLI.epic([action: :show, ids: [12], json: true])\n", 0}
  end

  test "V-25b list dispatch and help advertise epic commands" do
    assert shell("cmd_epic list --json") ==
             {"Aiur.AgentControlCLI.epic([action: :list, json: true])\n", 0}

    assert shell("aiur_engine_main epic list --json") ==
             {"Aiur.AgentControlCLI.epic([action: :list, json: true])\n", 0}

    {help, 0} = shell("usage")
    assert help =~ "epic set <epic>"
    assert help =~ "epic clear <ids...>"
    assert help =~ "epic show [<ids...>]"
    assert help =~ "epic list [--json]"
  end

  test "V-26 all usage failures exit 64 before RPC" do
    for args <- [
          "set",
          "set bugs",
          "set bugs abc",
          "set bugs 0",
          "set Bugs 12",
          "set bugs 12 --as 'a b'",
          "set bugs 12 --source agent:3",
          "set bugs 12 --bad",
          "show --source x",
          "list 12",
          "move",
          "set bugs 12 --as",
          "show --as x"
        ] do
      assert {output, 64} = shell("cmd_epic " <> args, [{"USER", "kevin"}])
      refute output =~ "Aiur.AgentControlCLI"
    end

    assert {out, 64} = shell("cmd_epic set bugs 12", [{"USER", ""}])
    assert out =~ "valid --as or USER"
  end
end
