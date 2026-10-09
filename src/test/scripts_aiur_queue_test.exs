defmodule Aiur.ScriptsQueueTest do
  use ExUnit.Case, async: true
  @handler Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-queue.sh", __DIR__)

  test "mutations refuse caller workspace and workspace paths before RPC" do
    for verb <- ["add", "remove", "reorder", "hold", "release"] do
      assert {output, 64} = command([verb, "1"], [{"AIUR_AGENT_WORKSPACE", "/caller"}])
      assert output =~ "aiur queue changes are blocked inside agent workspaces"
      refute output =~ "RPC:"
    end

    for variable <- ["PWD", "AIUR_PROJECT_ROOT", "AIUR_REPO_ROOT"] do
      assert {output, 64} = command(["add", "1"], [{if(variable == "PWD", do: "TEST_QUEUE_PWD", else: variable), "/host/aiur-workspaces/repo/1"}])
      refute output =~ "RPC:"
    end
  end

  # Existing read behavior is a deliberate future-regression guard, not mutation coverage.
  test "future regression: show is allowed in a workspace and encodes queue names safely" do
    assert {output, 0} = command(["show", "--queue", "a\"; raise :bad", "--json"], [{"AIUR_AGENT_WORKSPACE", "/caller"}])
    assert output =~ "RPC:"
    assert output =~ "json: true"
    refute output =~ "raise :bad"
  end

  test "all mutation flags and caller evidence reach RPC with sized add timeout" do
    assert {output, 0} = command(["add", "1", "2", "--queue", "paseo", "--after", "9", "--at", "0"])
    assert output =~ "verb: :add"
    assert output =~ "ids: [\"1\",\"2\"]"
    assert output =~ "after: \"9\""
    assert output =~ "at: 0"
    assert output =~ "caller_agent_workspace:"
    assert output =~ "TIMEOUT:21"
    assert {output, 0} = command(["add", "--build-order", "9", "--queue", "roadmap"])
    assert output =~ "build_order: 9"
    assert {output, 0} = command(["reorder", "1", "--to", "2"])
    assert output =~ "to: 2"
    for verb <- ["hold", "release"], do: assert({_, 0} = command([verb, "--queue", "paseo"]))
  end

  # Refusal-only inputs also passed the old show-only parser; valid verb wiring is covered above.
  test "future regression: malformed verbs flags and incompatible targets never attempt RPC" do
    for args <- [
          ["wat"],
          ["add"],
          ["remove", "--queue", "paseo"],
          ["show", "--at", "1"],
          ["hold", "1", "--queue", "paseo"],
          ["reorder", "1"],
          ["add", "1", "--at", "-1"],
          ["add", "1", "--build-order", "9"],
          ["add", "1", "--queue", ""],
          ["add", "1", "1"]
        ] do
      assert {output, 64} = command(args)
      refute output =~ "RPC:"
    end
  end

  defp command(args, overrides \\ []) do
    script =
      "source \"$1\"; shift; PWD=${TEST_QUEUE_PWD:-$PWD}; run_control_rpc() { echo \"RPC:$1 TIMEOUT:${AIUR_CONTROL_RPC_TIMEOUT_SECONDS:-10}\"; }; todo_rpc_seconds() { echo $((15 + 3 * $1)); }; cmd_queue \"$@\""

    env =
      [{"AIUR_AGENT_WORKSPACE", ""}, {"AIUR_PROJECT_ROOT", ""}, {"AIUR_REPO_ROOT", ""}, {"PWD", "/tmp"}, {"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", nil}]
      |> Map.new()
      |> Map.merge(Map.new(overrides))
      |> Map.to_list()

    System.cmd("bash", ["-c", script, "queue-test", @handler | args], cd: "/tmp", env: env, stderr_to_stdout: true)
  end
end
