defmodule Aiur.TestSupport.ExecutorSessionRPCAssertions do
  @moduledoc false
  import ExUnit.Assertions

  def env do
    [
      {"CLAUDE_CODE_SESSION_ID", "s-1"},
      {"CLAUDE_CONFIG_DIR", nil},
      {"CLAUDE_PID", nil},
      {"CLAUDE_CODE_CHILD_SESSION", nil},
      {"CODEX_THREAD_ID", nil},
      {"PWD", File.cwd!()},
      {"GITHUB_TOKEN", "must-not-reach-the-rpc"}
    ]
  end

  def assert_rpc(output, arguments) do
    session = Base.encode64("s-1")
    cwd = Base.encode64(File.cwd!())
    expected = ~s|RPC:Aiur.AgentControlCLI.executor_wait(#{arguments}, env: [{"CLAUDE_CODE_SESSION_ID", "#{session}"},{"PWD", "#{cwd}"},])|
    assert Enum.filter(String.split(output, "\n"), &String.starts_with?(&1, "RPC:")) == [expected]
  end
end
