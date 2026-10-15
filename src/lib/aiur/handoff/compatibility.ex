defmodule Aiur.Handoff.Compatibility do
  @moduledoc false
  alias Aiur.AppServer.RelayPort
  alias Aiur.{CodingAgent, Handoff, Tmux}

  @spec check(map(), map(), keyword()) :: :ok | {:error, atom()}
  def check(agent, record, opts \\ []) do
    fingerprint = Keyword.get_lazy(opts, :config_fingerprint, &Handoff.config_fingerprint/0)
    probe = Keyword.get(opts, :relay_probe, &RelayPort.inspect_relay/1)

    with :ok <- prepared_fallback(agent),
         :ok <- transport(agent["transport"], probe),
         :ok <- require_match(Map.get(agent, "config_fingerprint", record["config_fingerprint"]) == fingerprint, :config_changed),
         :ok <- require_match(is_binary(agent["workspace"]) and File.dir?(agent["workspace"]), :workspace_missing),
         :ok <- require_match(agent["backend"] in CodingAgent.known_backends(), :backend_unknown) do
      require_match(is_nil(agent["worker_host"]), :remote_worker)
    end
  end

  defp prepared_fallback(%{"fallback_reason" => "remote_worker"}), do: {:error, :remote_worker}
  defp prepared_fallback(%{"fallback_reason" => "relay_protocol"}), do: {:error, :relay_protocol}
  defp prepared_fallback(_agent), do: :ok

  defp transport(%{"kind" => "relay", "directory" => directory} = expected, probe) do
    with :ok <- require_match(expected["protocol"] in [1], :relay_protocol),
         {:ok, actual} <- probe.(directory) do
      with :ok <- require_match(actual["protocol"] in [1], :relay_protocol),
           :ok <- require_match(same_identity?(expected, actual), :relay_gone) do
        require_match(actual["lossy"] == false, :relay_lossy)
      end
    else
      {:error, reason} when reason in [:relay_protocol, :relay_gone, :relay_lossy] -> {:error, reason}
      _ -> {:error, :relay_gone}
    end
  end

  defp transport(%{"kind" => "repl", "pane_id" => pane, "socket" => socket}, _probe) do
    server = if is_binary(socket), do: {:socket, Tmux, socket}, else: Tmux
    require_match(match?({:ok, _}, Tmux.pane_pid(server, pane)), :relay_gone)
  end

  defp transport(_, _), do: {:error, :relay_gone}

  defp same_identity?(expected, actual) do
    Enum.all?(~w(spawn_nonce provider_pid relay_id), fn key ->
      not is_nil(expected[key]) and expected[key] == actual[key]
    end)
  end

  defp require_match(true, _reason), do: :ok
  defp require_match(false, reason), do: {:error, reason}
end
