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

  test "init probes the selected Codex sandbox and reports its actual failure" do
    parent = self()

    io = %{
      puts: fn message -> send(parent, {:warning, IO.chardata_to_string(message)}) end,
      confirm: fn _message, _default -> false end
    }

    deps = %{
      check_agent_auth: fn "codex" -> :ok end,
      check_codex_sandbox: fn ->
        send(parent, :sandbox_probed)
        {:error, "bwrap: setting up uid map: Permission denied. See https://aiur.team/docs/guide/quick-start#codex-on-linux"}
      end
    }

    assert :ok = AgentCli.check_agent_clis(io, deps, ["codex"])
    assert_received :sandbox_probed
    assert_received {:warning, warning}
    assert warning =~ "bwrap: setting up uid map: Permission denied"
    assert warning =~ "https://aiur.team/docs/guide/quick-start#codex-on-linux"
  end

  # Future guard for the existing selected-backend filter and the new
  # present-CLI gate; this is not counted as coverage of the probe itself.
  test "future guard: init skips the Codex probe when unselected or unavailable" do
    parent = self()
    io = %{puts: fn _message -> :ok end, confirm: fn _message, _default -> false end}

    deps = %{
      check_agent_auth: fn backend -> if backend == "codex", do: {:error, "codex missing"}, else: :ok end,
      check_codex_sandbox: fn -> send(parent, :sandbox_probed) end
    }

    assert :ok = AgentCli.check_agent_clis(io, deps, ["muse"])
    assert :ok = AgentCli.check_agent_clis(io, deps, ["codex"])
    refute_received :sandbox_probed
  end

  test "the bounded sandbox probe includes Codex's diagnostic output" do
    root = Aiur.TestSupport.tmp_root!("codex-sandbox-probe")
    executable = Path.join(root, "codex-probe")
    File.mkdir_p!(root)

    File.write!(
      executable,
      "#!/bin/sh\n[ \"$1\" = sandbox ] && [ \"$2\" = -- ] && [ \"$3\" = /bin/pwd ] || exit 7\nprintf 'bwrap: setting up uid map: Permission denied\\n' >&2\nexit 1\n"
    )

    File.chmod!(executable, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, message} = AgentCli.run_codex_sandbox_probe(executable, 500)
    assert message =~ "codex sandbox -- /bin/pwd exited 1"
    assert message =~ "bwrap: setting up uid map: Permission denied"
    assert message =~ "https://aiur.team/docs/guide/quick-start#codex-on-linux"
  end

  test "the sandbox probe stops waiting at its deadline" do
    root = Aiur.TestSupport.tmp_root!("codex-sandbox-timeout")
    executable = Path.join(root, "codex-probe")
    File.mkdir_p!(root)
    File.write!(executable, "#!/bin/sh\nsleep 2\n")
    File.chmod!(executable, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, message} = AgentCli.run_codex_sandbox_probe(executable, 50)
    assert message =~ "timed out after 50ms"
  end

  test "the sandbox probe keeps the final diagnostic after a long startup banner" do
    root = Aiur.TestSupport.tmp_root!("codex-sandbox-long-output")
    executable = Path.join(root, "codex-probe")
    File.mkdir_p!(root)
    File.write!(executable, "#!/bin/sh\nprintf '%05000d' 0 >&2\nprintf '\\nbwrap: setting up uid map: Permission denied\\n' >&2\nexit 1\n")
    File.chmod!(executable, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, message} = AgentCli.run_codex_sandbox_probe(executable, 500)
    assert message =~ "bwrap: setting up uid map: Permission denied"
  end
end
