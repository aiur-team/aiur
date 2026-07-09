defmodule Aiur.Init.AgentCliTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.AgentCli

  describe "install_hint/2" do
    test "claude hint mentions npm install -g aiur-claude" do
      hint = AgentCli.install_hint("claude", "anything")
      assert hint =~ "npm install -g aiur-claude"
    end

    test "codex hint mentions the exe and PATH" do
      hint = AgentCli.install_hint("codex", "codex")
      assert hint =~ "codex"
      assert hint =~ "PATH"
    end
  end

  describe "agent_executable/1" do
    test "claude returns first token of configured command" do
      cmd = Aiur.Claude.Config.command()
      expected = if cmd, do: cmd |> String.split() |> List.first(), else: nil
      assert AgentCli.agent_executable("claude") == expected
    end

    test "codex returns first token of configured command" do
      cmd = Aiur.Codex.Config.command()
      expected = if cmd, do: cmd |> String.split() |> List.first(), else: nil
      assert AgentCli.agent_executable("codex") == expected
    end

    test "unknown kind returns nil" do
      assert AgentCli.agent_executable("nope") == nil
    end
  end

  describe "check_agent_auth/1" do
    test "unknown kind returns exact error message" do
      assert AgentCli.check_agent_auth("nope") == {:error, "no command configured for nope"}
    end
  end
end
