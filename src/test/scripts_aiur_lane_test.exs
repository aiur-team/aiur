defmodule Aiur.ScriptsLaneTest do
  use ExUnit.Case, async: true
  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)
  defp shell(command, env \\ []) do
    System.cmd(
      "bash",
      [
        "-c",
        ~S|source "$1"; run_control_rpc() { printf '%s\n' "$1"; }; | <> command,
        "lane-test",
        @engine
      ],
      env: env,
      stderr_to_stdout: true
    )
  end

  # Write verbs through the deprecated `aiur epic` spelling add a deprecation
  # line on stderr; the RPC helper keeps that out of the compared stdout.
  defp rpc(command, env \\ []) do
    System.cmd(
      "bash",
      [
        "-c",
        ~S|source "$1"; run_control_rpc() { printf '%s\n' "$1"; }; | <> command <> " 2>/dev/null",
        "lane-test",
        @engine
      ],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp stderr_only(command, env \\ []) do
    System.cmd(
      "bash",
      [
        "-c",
        ~S|source "$1"; run_control_rpc() { :; }; | <> command <> " >/dev/null",
        "lane-test",
        @engine
      ],
      env: env,
      stderr_to_stdout: true
    )
  end

  test "V-25 batch command encodes actor and lane and normalizes hash ids" do
    assert rpc("cmd_epic set bugs 12 '#13' --as kevin --json") ==
             {"Aiur.AgentControlCLI.lane([action: :set, epic: Base.decode64!(\"YnVncw==\"), ids: [12, 13], who: Base.decode64!(\"a2V2aW4=\"), source: :cli, json: true])\n", 0}

    assert {text, 0} = shell("cmd_epic set bugs 12 --as kevin --source backfill-agent")
    assert text =~ "source: :\"backfill-agent\""
    assert {text, 0} = shell("cmd_epic clear '#12' --as kevin --json")
    assert text =~ "action: :clear, ids: [12]"

    assert shell("cmd_lane show 12 --json") ==
             {"Aiur.AgentControlCLI.lane([action: :show, ids: [12], json: true])\n", 0}
  end

  test "V-25b list dispatch and help advertise lane commands" do
    assert shell("cmd_lane list --json") ==
             {"Aiur.AgentControlCLI.lane([action: :list, json: true])\n", 0}

    assert shell("aiur_engine_main lane list --json") ==
             {"Aiur.AgentControlCLI.lane([action: :list, json: true])\n", 0}

    # `aiur epic list` now reads epic records, so it leaves the lane store alone.
    assert shell("aiur_engine_main epic list --json") ==
             {"Aiur.AgentControlCLI.epic([action: :list, json: true])\n", 0}

    {help, 0} = shell("usage")
    assert help =~ "lane set <lane>"
    assert help =~ "lane clear <ids...>"
    assert help =~ "lane confirm <ids...>"
    assert help =~ "lane show [<ids...>]"
    assert help =~ "lane list [--json]"
    assert help =~ "epic set|clear|confirm"
  end

  test "confirm encodes guarded lane, actor and deduplicated IDs; show accepts the filter" do
    assert rpc("cmd_epic confirm 12 '#14' 12 --epic infra --as kevin --json") ==
             {"Aiur.AgentControlCLI.lane([action: :confirm, ids: [12, 14], expect_epic: Base.decode64!(\"aW5mcmE=\"), who: Base.decode64!(\"a2V2aW4=\"), json: true])\n", 0}

    assert shell("cmd_lane show --unconfirmed --json") ==
             {"Aiur.AgentControlCLI.lane([action: :show, unconfirmed: true, json: true])\n", 0}

    assert rpc("cmd_lane confirm 12 --lane infra --as kevin --json") ==
             {"Aiur.AgentControlCLI.lane([action: :confirm, ids: [12], expect_epic: Base.decode64!(\"aW5mcmE=\"), who: Base.decode64!(\"a2V2aW4=\"), json: true])\n", 0}
  end

  test "ae6 the epic write verbs print a deprecation naming aiur lane and still dispatch" do
    for verb <- ~w(set clear confirm) do
      args = if verb == "set", do: "ui 812", else: "812"
      {stderr, 0} = stderr_only("aiur_engine_main epic " <> verb <> " " <> args <> " --as kevin")
      assert stderr =~ "aiur: epic #{verb} is deprecated; use aiur lane #{verb}"

      {rpc, 0} = shell("aiur_engine_main epic " <> verb <> " " <> args <> " --as kevin")
      assert rpc =~ "Aiur.AgentControlCLI.lane([action: :#{verb}"
    end
  end

  test "the lane verbs print no deprecation line" do
    {stderr, 0} = stderr_only("aiur_engine_main lane set ui 812 --as kevin")
    refute stderr =~ "deprecated"
  end

  @tag :future_regression
  test "future regression guard: confirm rejects invalid arguments before dispatch" do
    for args <- [
          "confirm",
          "confirm 0",
          "confirm 12 --epic 'X;rm'",
          "confirm 12 --epic Infra",
          "confirm 12 --as 'a b'",
          "confirm 12 --source backfill-agent",
          "confirm 12 --unconfirmed",
          "confirm 12 --epic",
          "confirm " <> Enum.join(1..201, " ")
        ] do
      assert {output, 64} = shell("cmd_epic " <> args, [{"USER", "tester"}])
      refute output =~ "Aiur.AgentControlCLI"
    end

    assert {output, 64} = shell("cmd_epic confirm 12", [{"USER", ""}])
    refute output =~ "Aiur.AgentControlCLI"
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
