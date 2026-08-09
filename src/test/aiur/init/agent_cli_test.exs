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

  describe "check_claude_version/1" do
    test "a version below the minimum warns about the missing coordination tools" do
      assert {:error, message} = AgentCli.check_claude_version({:ok, "1.0.0"})
      assert message =~ "aiur-claude 1.0.0 is older than 1.1.0"
      assert message =~ "without Aiur coordination tools"
      assert message =~ "aiur_declare_blocker"
      assert message =~ "npm install -g aiur-claude@1.1.0"
    end

    test "a version at the minimum is silent" do
      assert AgentCli.check_claude_version({:ok, "1.1.0"}) == :ok
    end

    test "a version above the minimum is silent" do
      assert AgentCli.check_claude_version({:ok, "2.3.1"}) == :ok
    end

    test "an unparseable version degrades to a hedged warning" do
      assert {:error, message} = AgentCli.check_claude_version({:ok, "nightly"})
      assert message =~ "couldn't parse the aiur-claude version (nightly)"
      assert message =~ "if it's older than 1.1.0"
      assert message =~ "npm install -g aiur-claude@1.1.0"
    end

    test "an undetectable version degrades to a hedged warning naming the reason" do
      assert {:error, message} = AgentCli.check_claude_version({:error, "aiur-claude unavailable"})
      assert message =~ "couldn't check the aiur-claude version (aiur-claude unavailable)"
      assert message =~ "if it's older than 1.1.0"
      assert message =~ "without Aiur coordination tools"
    end

    test "a prerelease of the minimum counts as below it" do
      assert {:error, message} = AgentCli.check_claude_version({:ok, "1.1.0-rc.1"})
      assert message =~ "older than 1.1.0"
    end
  end

  describe "min_claude_version/0" do
    test "is the first adapter release that serves dynamicTools" do
      assert AgentCli.min_claude_version() == "1.1.0"
    end
  end

  describe "check_agent_auth/1" do
    test "unknown kind returns exact error message" do
      assert AgentCli.check_agent_auth("nope") == {:error, "no command configured for nope"}
    end
  end

  test "does not check a non-configurable transport backend during init" do
    parent = self()
    io = %{puts: fn _message -> :ok end, confirm: fn _message, _default -> false end}

    deps = %{
      check_agent_auth: fn backend ->
        send(parent, {:checked, backend})
        :ok
      end
    }

    assert :ok = AgentCli.check_agent_clis(io, deps, ["claude-repl"])
    refute_received {:checked, "claude-repl"}
  end
end
