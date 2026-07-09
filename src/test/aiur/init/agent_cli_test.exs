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
    test "claude returns a binary executable name" do
      result = AgentCli.agent_executable("claude")
      assert is_binary(result) or is_nil(result)
    end

    test "codex returns a binary executable name" do
      result = AgentCli.agent_executable("codex")
      assert is_binary(result) or is_nil(result)
    end

    test "unknown kind returns nil" do
      assert AgentCli.agent_executable("nope") == nil
    end
  end

  describe "check_agent_auth/1" do
    test "unknown kind returns error with kind in message" do
      assert {:error, msg} = AgentCli.check_agent_auth("nope")
      assert msg =~ "nope"
    end
  end
end
