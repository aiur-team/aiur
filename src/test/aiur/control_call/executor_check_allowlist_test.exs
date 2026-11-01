defmodule Aiur.ControlCall.ExecutorCheckAllowlistTest do
  use ExUnit.Case, async: true
  alias Aiur.ControlCall

  @expression ~s|Aiur.AgentControlCLI.executor_check(json: true, repo_root: "/repo")|

  test "executor diagnostics remain local-only even for read-only remote callers" do
    assert {:error, :denied_remote} = ControlCall.parse(@expression)
    assert {:error, :denied_remote} = ControlCall.parse(@expression, remote: true, max_scope: :read)
  end

  test "local executor diagnostics preserve their validated arguments" do
    assert {:ok, %{module: Aiur.AgentControlCLI, function: :executor_check, args: [[json: true, repo_root: "/repo"]], scope: :deny}} =
             ControlCall.parse(@expression, remote: false)
  end

  test "executor diagnostics reject malformed and unexpected options before dispatch" do
    for expression <- [
          ~s|Aiur.AgentControlCLI.executor_check(json: "true", repo_root: "/repo")|,
          ~s|Aiur.AgentControlCLI.executor_check(json: true, repo_root: "")|
        ] do
      assert {:error, :non_literal_argument} = ControlCall.parse(expression, remote: false)
    end

    assert {:error, :option_not_allowed} =
             ControlCall.parse(~s|Aiur.AgentControlCLI.executor_check(json: true, repo_root: "/repo", harness: "claude")|, remote: false)
  end
end
