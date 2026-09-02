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

  describe "min_claude_version/0" do
    test "is the first adapter release that serves dynamicTools" do
      assert AgentCli.min_claude_version() == "1.1.0"
    end
  end

  describe "classify_claude_install/1" do
    test "classifies missing, satisfying, outdated, and unreadable installs" do
      assert AgentCli.classify_claude_install(:missing) == :missing
      assert AgentCli.classify_claude_install({:ok, "1.1.0"}) == {:satisfying, "1.1.0"}
      assert AgentCli.classify_claude_install({:ok, "2.0.0"}) == {:satisfying, "2.0.0"}
      assert AgentCli.classify_claude_install({:ok, "1.0.9"}) == {:outdated, "1.0.9"}
      assert AgentCli.classify_claude_install({:ok, "1.1.0-rc.1"}) == {:outdated, "1.1.0-rc.1"}

      assert AgentCli.classify_claude_install({:ok, "nightly"}) ==
               {:unknown, "unparseable version: nightly"}

      assert AgentCli.classify_claude_install({:error, "permission denied"}) ==
               {:unknown, "permission denied"}
    end
  end

  describe "claude_install_spec/1" do
    test "pins a satisfying registry version exactly" do
      assert AgentCli.claude_install_spec({:ok, "1.4.2"}) == "aiur-claude@1.4.2"
    end

    test "uses the reviewed immutable release when npm is old, unreadable, or unavailable" do
      fallback = "github:aiur-team/aiur-claude#v1.1.0"
      assert AgentCli.claude_install_spec({:ok, "1.0.0"}) == fallback
      assert AgentCli.claude_install_spec({:ok, "latest"}) == fallback
      assert AgentCli.claude_install_spec({:error, "registry offline"}) == fallback
    end
  end

  describe "check_agent_clis/3 claude installation" do
    test "a satisfying adapter is never installed even when its auth probe fails" do
      parent = self()

      deps =
        claude_deps(parent, %{
          claude_version: fn -> {:ok, "1.2.0"} end,
          claude_registry_version: fn -> flunk("registry must not be queried") end
        })

      assert :ok = AgentCli.check_agent_clis(test_io(parent), deps, ["claude"])
      refute_received {:install, _spec}
      assert_received {:auth, "claude"}
      assert_received {:puts, message}
      assert message =~ "Found aiur-claude 1.2.0"
      assert message =~ "leaving it unchanged"
    end

    test "an outdated adapter installs an exact satisfying npm version" do
      parent = self()
      {:ok, versions} = Agent.start_link(fn -> [{:ok, "1.0.0"}, {:ok, "1.3.0"}] end)

      deps =
        claude_deps(parent, %{
          claude_version: fn -> Agent.get_and_update(versions, fn [next | rest] -> {next, rest} end) end,
          claude_registry_version: fn -> {:ok, "1.3.0"} end
        })

      assert :ok = AgentCli.check_agent_clis(test_io(), deps, ["claude"])
      assert_received {:install, "aiur-claude@1.3.0"}
    end

    test "an unreadable existing adapter is not mutated and stops setup" do
      parent = self()

      deps =
        claude_deps(parent, %{
          claude_version: fn -> {:error, "--version exited 126"} end,
          claude_registry_version: fn -> flunk("registry must not be queried") end
        })

      assert {:error, message} = AgentCli.check_agent_clis(test_io(), deps, ["claude"])
      refute_received {:install, _spec}
      refute_received {:auth, "claude"}
      assert message =~ "setup failed"
      assert message =~ "could not be verified"
      assert message =~ "left unchanged"
    end

    test "a post-install version below the minimum is terminal" do
      parent = self()
      {:ok, versions} = Agent.start_link(fn -> [:missing, {:ok, "1.0.0"}] end)

      deps =
        claude_deps(parent, %{
          claude_version: fn -> Agent.get_and_update(versions, fn [next | rest] -> {next, rest} end) end,
          claude_registry_version: fn -> {:ok, "1.0.0"} end
        })

      assert {:error, message} = AgentCli.check_agent_clis(test_io(), deps, ["claude"])
      assert_received {:install, "github:aiur-team/aiur-claude#v1.1.0"}
      assert message =~ "installed aiur-claude 1.0.0"
      assert message =~ "requires 1.1.0 or newer"
    end

    test "an install failure is terminal" do
      deps = claude_deps(self(), %{install_claude_app_server: fn _spec -> {:error, "npm failed"} end})

      assert {:error, message} = AgentCli.check_agent_clis(test_io(), deps, ["claude"])
      assert message =~ "couldn't install aiur-claude"
      assert message =~ "npm failed"
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

  defp test_io(parent \\ nil) do
    %{
      puts: fn message ->
        if parent, do: send(parent, {:puts, message})
        :ok
      end,
      confirm: fn _message, _default -> false end
    }
  end

  defp claude_deps(parent, overrides) do
    Map.merge(
      %{
        claude_version: fn -> :missing end,
        claude_registry_version: fn -> {:ok, "1.1.0"} end,
        install_claude_app_server: fn spec ->
          send(parent, {:install, spec})
          :ok
        end,
        check_agent_auth: fn kind ->
          send(parent, {:auth, kind})
          {:error, "not authenticated"}
        end
      },
      overrides
    )
  end
end
