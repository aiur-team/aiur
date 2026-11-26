defmodule Aiur.ScriptsEpicTest do
  use ExUnit.Case, async: true
  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  # `run_control_rpc` prints the expression the launcher would send instead of
  # dialing the daemon, so these cases pin the parser without a live engine.
  defp rpc(command, env \\ []) do
    System.cmd(
      "bash",
      [
        "-c",
        ~S|source "$1"; run_control_rpc() { printf '%s\n' "$1"; }; | <> command <> " 2>/dev/null",
        "epic-test",
        @engine
      ],
      cd: "/",
      env: [{"USER", "tester"} | env],
      stderr_to_stdout: true
    )
  end

  # Usage refusals print on stderr, so the guard keeps both streams.
  defp shell(command, env \\ []) do
    System.cmd(
      "bash",
      [
        "-c",
        ~S|source "$1"; run_control_rpc() { printf '%s\n' "$1"; }; | <> command,
        "epic-test",
        @engine
      ],
      cd: "/",
      env: [{"USER", "tester"} | env],
      stderr_to_stdout: true
    )
  end

  test "epic create and edit encode the record fields" do
    assert rpc("cmd_epic create bugs --label Bugs --icon bug-ant --hue 200 --root 12 --as kevin --json") ==
             {"Aiur.AgentControlCLI.epic([action: :create, slug: Base.decode64!(\"YnVncw==\"), who: Base.decode64!(\"a2V2aW4=\"), label: Base.decode64!(\"QnVncw==\"), icon: Base.decode64!(\"YnVnLWFudA==\"), hue: 200, root: 12, json: true])\n",
              0}

    assert rpc("cmd_epic edit bugs --label Renamed --hue 359") ==
             {"Aiur.AgentControlCLI.epic([action: :edit, slug: Base.decode64!(\"YnVncw==\"), who: Base.decode64!(\"dGVzdGVy\"), label: Base.decode64!(\"UmVuYW1lZA==\"), hue: 359])\n", 0}
  end

  test "epic add and remove deduplicate feature slugs" do
    assert rpc("cmd_epic add combat-epic combat combat khala-srv --json") ==
             {"Aiur.AgentControlCLI.epic([action: :add, slug: Base.decode64!(\"Y29tYmF0LWVwaWM=\"), features: [Base.decode64!(\"Y29tYmF0\"), Base.decode64!(\"a2hhbGEtc3J2\")], who: Base.decode64!(\"dGVzdGVy\"), json: true])\n",
              0}

    assert rpc("cmd_epic remove combat-epic combat") ==
             {"Aiur.AgentControlCLI.epic([action: :remove, slug: Base.decode64!(\"Y29tYmF0LWVwaWM=\"), features: [Base.decode64!(\"Y29tYmF0\")], who: Base.decode64!(\"dGVzdGVy\")])\n", 0}
  end

  test "epic show and list read records and accept an optional slug" do
    assert rpc("cmd_epic show bugs --json") ==
             {"Aiur.AgentControlCLI.epic([action: :show, slug: Base.decode64!(\"YnVncw==\"), json: true])\n", 0}

    assert rpc("cmd_epic show") == {"Aiur.AgentControlCLI.epic([action: :show])\n", 0}
    assert rpc("cmd_epic list --json") == {"Aiur.AgentControlCLI.epic([action: :list, json: true])\n", 0}
    assert rpc("aiur_engine_main epic list --json") == {"Aiur.AgentControlCLI.epic([action: :list, json: true])\n", 0}
  end

  test "epic set clear and confirm still dispatch to the lane commands" do
    for {verb, args} <- [{"set", "ui 812"}, {"clear", "812"}, {"confirm", "812"}] do
      {output, 0} = rpc("aiur_engine_main epic " <> verb <> " " <> args <> " --as kevin")
      assert output =~ "Aiur.AgentControlCLI.lane([action: :#{verb}"
    end
  end

  @tag :future_regression
  test "future regression guard: epic usage failures exit 64 before RPC" do
    for args <- [
          "create bugs",
          "create Bugs --label Bugs",
          "create bugs --label",
          "create bugs --label Bugs --hue 400",
          "create bugs --label Bugs --root 0",
          "create bugs --label Bugs --root 2147483648",
          "add combat-epic",
          "add combat-epic Combat",
          "add combat-epic combat --root 12",
          "edit combat-epic",
          "remove",
          "show bugs --as kevin",
          "show --label Bugs",
          "list 12",
          "unknown"
        ] do
      assert {output, 64} = shell("cmd_epic " <> args)
      refute output =~ "Aiur.AgentControlCLI"
    end

    assert {output, 64} = shell("cmd_epic create bugs --label Bugs", [{"USER", ""}])
    refute output =~ "Aiur.AgentControlCLI"
  end
end
