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

  describe "check_claude_version/2" do
    test "a version below the minimum warns about the missing coordination tools" do
      assert {:error, message} = AgentCli.check_claude_version({:ok, "1.0.0"}, :available)
      assert message =~ "aiur-claude 1.0.0 is older than 1.1.0"
      assert message =~ "without Aiur coordination tools"
      assert message =~ "aiur_declare_blocker"
      assert message =~ "npm install -g aiur-claude@1.1.0"
    end

    test "a version at the minimum is silent" do
      assert AgentCli.check_claude_version({:ok, "1.1.0"}, :not_found) == :ok
    end

    test "a version above the minimum is silent" do
      assert AgentCli.check_claude_version({:ok, "2.3.1"}, :not_found) == :ok
    end

    test "an unparseable version degrades to a hedged warning" do
      assert {:error, message} =
               AgentCli.check_claude_version({:ok, "nightly"}, {:unknown, :timeout})

      assert message =~ "couldn't determine the aiur-claude version"
      assert message =~ "if it's older than 1.1.0"
      assert message =~ "npm install -g aiur-claude@1.1.0"
    end

    test "an undetectable version degrades without echoing raw diagnostics" do
      assert {:error, message} =
               AgentCli.check_claude_version({:error, "token=super-secret"}, {:unknown, :timeout})

      assert message =~ "couldn't determine the aiur-claude version"
      assert message =~ "if it's older than 1.1.0"
      assert message =~ "without Aiur coordination tools"
      refute message =~ "super-secret"
    end

    test "a prerelease of the minimum counts as below it" do
      assert {:error, message} = AgentCli.check_claude_version({:ok, "1.1.0-rc.1"}, :available)
      assert message =~ "older than 1.1.0"
    end
  end

  describe "min_claude_version/0" do
    test "is the first adapter release that serves dynamicTools" do
      assert AgentCli.min_claude_version() == "1.1.0"
    end
  end

  describe "install_claude_app_server/2" do
    test "a clean install runs npm once and never uninstalls" do
      parent = self()

      cmd_fun = fn _npm, args, _opts ->
        send(parent, {:npm, args})
        {"added 1 package", 0}
      end

      assert :ok =
               AgentCli.install_claude_app_server("aiur-claude@1.1.0", npm_path: "/usr/bin/npm", cmd_fun: cmd_fun)

      assert_received {:npm, ["install", "-g", "aiur-claude@1.1.0"]}
      refute_received {:npm, ["uninstall" | _rest]}
    end

    # A global install over a half-removed package fails with ENOTEMPTY, and
    # the documented remedy is to uninstall first — so do it, rather than
    # handing the operator a failure they would have to fix by hand.
    test "a failed install retries once after uninstalling the leftover package" do
      parent = self()
      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> Aiur.TestSupport.safe_stop(attempts) end)

      cmd_fun = fn _npm, args, _opts ->
        send(parent, {:npm, args})

        case args do
          ["install" | _rest] ->
            if Agent.get_and_update(attempts, &{&1, &1 + 1}) == 0,
              do: {"ENOTEMPTY: directory not empty", 1},
              else: {"added 1 package", 0}

          ["uninstall" | _rest] ->
            {"removed 1 package", 0}
        end
      end

      assert :ok =
               AgentCli.install_claude_app_server("aiur-claude@1.1.0", npm_path: "/usr/bin/npm", cmd_fun: cmd_fun)

      assert_received {:npm, ["install", "-g", "aiur-claude@1.1.0"]}
      assert_received {:npm, ["uninstall", "-g", "aiur-claude"]}
      assert_received {:npm, ["install", "-g", "aiur-claude@1.1.0"]}
    end

    test "a retry that still fails reports the original install error" do
      cmd_fun = fn _npm, args, _opts ->
        case args do
          ["install" | _rest] -> {"ENOTEMPTY: directory not empty", 1}
          ["uninstall" | _rest] -> {"EACCES: permission denied", 1}
        end
      end

      assert {:error, message} =
               AgentCli.install_claude_app_server("aiur-claude@1.1.0", npm_path: "/usr/bin/npm", cmd_fun: cmd_fun)

      assert message =~ "ENOTEMPTY"
    end

    test "a missing npm never shells out" do
      cmd_fun = fn _npm, _args, _opts -> flunk("npm must not run when it is absent") end

      assert {:error, "npm not found on PATH"} =
               AgentCli.install_claude_app_server("aiur-claude@1.1.0", npm_path: nil, cmd_fun: cmd_fun)
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
