defmodule Aiur.CLI.RuntimeDeps do
  @moduledoc false

  @spec get() :: Aiur.CLI.deps()
  def get do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &Aiur.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      set_server_host_override: &set_server_host_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:aiur) end,
      configured_max_agents: &Aiur.Config.max_concurrent_agents/0,
      executor_mode?: fn -> Application.get_env(:aiur, :executor_mode, false) end,
      check_daemon_gap: &Aiur.DaemonHeartbeatChecker.check_and_alert!/0
    }
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:aiur, :log_file, Aiur.LogFile.default_log_file(logs_root))
    :ok
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:aiur, :server_port_override, port)
    :ok
  end

  defp set_server_host_override(host) when is_binary(host) and host != "" do
    Application.put_env(:aiur, :server_host_override, host)
    :ok
  end
end
