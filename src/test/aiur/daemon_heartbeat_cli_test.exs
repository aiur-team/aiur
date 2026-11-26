defmodule Aiur.DaemonHeartbeatCLITest do
  use ExUnit.Case, async: false

  alias Aiur.CLI

  test "Executor startup checks for a retrospective heartbeat gap before starting the app" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      executor_mode?: fn -> true end,
      check_daemon_gap: fn ->
        send(parent, :gap_checked)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :application_started)
        {:ok, [:aiur]}
      end
    }

    assert :ok = CLI.run("config.yaml", deps)
    assert_received :gap_checked
    assert_received :application_started
  end
end
