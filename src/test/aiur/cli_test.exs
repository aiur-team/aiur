defmodule Aiur.CLITest do
  use ExUnit.Case, async: true

  alias Aiur.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  defp deps do
    %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }
  end

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      set_server_host_override: fn _host ->
        send(parent, :host_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:aiur]}
      end
    }

    assert {:error, banner} = CLI.evaluate([".aiurconfig"], deps)
    assert banner =~ "This Aiur implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "Aiur is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :host_set
    refute_received :started
  end

  test "defaults to .aiur/config when workflow path is missing" do
    deps = %{
      file_regular?: fn path ->
        Path.basename(path) == "config" and Path.basename(Path.dirname(path)) == ".aiur"
      end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/operator.config"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", ".aiurconfig"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "accepts --host and passes the bind host to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn host ->
        send(parent, {:host, host})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--host", "127.0.0.1", ".aiurconfig"], deps)
    assert_received {:host, "127.0.0.1"}
  end

  test "rejects --host with an empty value" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "--host", "   ", ".aiurconfig"], deps)
    assert message =~ "Usage: aiur"
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, ".aiurconfig"], deps)
    assert message =~ "Config file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, ".aiurconfig"], deps)
    assert message =~ "Failed to start Aiur with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, ".aiurconfig"], deps)
  end

  test "routes a bare init subcommand to the wizard with force false" do
    assert {:init, %{force: false}} = CLI.evaluate(["init"], deps())
  end

  test "routes init --force to the wizard with force true" do
    assert {:init, %{force: true}} = CLI.evaluate(["init", "--force"], deps())
  end

  test "rejects init with extra positional arguments" do
    assert {:error, message} = CLI.evaluate(["init", "extra"], deps())
    assert message =~ "Usage: aiur"
  end

  test "does not treat a non-init positional as a subcommand" do
    parent = self()

    deps =
      Map.merge(deps(), %{
        file_regular?: fn path ->
          send(parent, {:workflow_checked, path})
          true
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "some/.aiurconfig"], deps)
    assert_received {:workflow_checked, _path}
  end

  test "routes variadic todo IDs and only without starting the workflow" do
    assert {:todo, ["11", "12", "13"], %{only: true}} =
             CLI.evaluate(["--todo", "11", "12,13", "--only"], deps())
  end

  test "deduplicates todo IDs in first-seen order" do
    assert {:todo, ["11", "12"], %{only: false}} =
             CLI.evaluate(["--todo", "11", "12", "11"], deps())
  end

  test "rejects todo without IDs" do
    assert {:error, message} = CLI.evaluate(["--todo"], deps())
    assert message =~ "aiur --todo <id>"
  end

  test "rejects invalid todo IDs" do
    assert {:error, message} = CLI.evaluate(["--todo", "11", "not-an-id"], deps())
    assert message =~ "aiur --todo <id>"
  end

  test "rejects only without todo" do
    assert {:error, message} = CLI.evaluate(["--only"], deps())
    assert message =~ "aiur --todo <id>"
  end

  test "rejects run flags combined with todo" do
    assert {:error, message} = CLI.evaluate(["--todo", "11", "--host", "127.0.0.1"], deps())
    assert message =~ "aiur --todo <id>"
  end

  test "enables interactive CLI mode when requested" do
    previous_value = Application.get_env(:aiur, :interactive_cli)

    on_exit(fn ->
      if is_nil(previous_value) do
        Application.delete_env(:aiur, :interactive_cli)
      else
        Application.put_env(:aiur, :interactive_cli, previous_value)
      end
    end)

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--interactive", ".aiurconfig"], deps)
    assert Application.get_env(:aiur, :interactive_cli) == true
  end

  defp passthrough_deps do
    %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }
  end

  test "enables headless mode when requested" do
    previous = Application.get_env(:aiur, :headless)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:aiur, :headless),
        else: Application.put_env(:aiur, :headless, previous)
    end)

    Application.delete_env(:aiur, :headless)

    assert :ok = CLI.evaluate([@ack_flag, "--headless", ".aiurconfig"], passthrough_deps())
    assert Application.get_env(:aiur, :headless) == true
  end

  test "--max-agents N records the orchestrator launch override" do
    previous = Application.get_env(:aiur, :max_concurrent_agents_override)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:aiur, :max_concurrent_agents_override),
        else: Application.put_env(:aiur, :max_concurrent_agents_override, previous)
    end)

    Application.delete_env(:aiur, :max_concurrent_agents_override)

    assert :ok = CLI.evaluate([@ack_flag, "--max-agents", "4", ".aiurconfig"], passthrough_deps())
    assert Application.get_env(:aiur, :max_concurrent_agents_override) == 4
  end

  test "--max-agents rejects a non-positive value" do
    previous = Application.get_env(:aiur, :max_concurrent_agents_override)
    Application.delete_env(:aiur, :max_concurrent_agents_override)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:aiur, :max_concurrent_agents_override),
        else: Application.put_env(:aiur, :max_concurrent_agents_override, previous)
    end)

    assert {:error, message} = CLI.evaluate([@ack_flag, "--max-agents", "0", ".aiurconfig"], passthrough_deps())
    assert message =~ "Usage: aiur"
    assert Application.get_env(:aiur, :max_concurrent_agents_override) == nil
  end
end
