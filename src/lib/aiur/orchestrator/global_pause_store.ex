defmodule Aiur.Orchestrator.GlobalPauseStore do
  @moduledoc """
  Crash-safe persistence for the daemon-wide pause switch and its provenance.

  The switch is intentionally durable: restarting Aiur must not silently
  release a fleet an operator deliberately parked.
  """

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @default %{globally_paused: false, paused_at: nil, source: nil}

  @spec load() :: %{globally_paused: boolean(), paused_at: DateTime.t() | nil, source: String.t() | nil}
  def load do
    case JsonStore.read(path_for(), %{}) do
      {:ok, persisted} ->
        normalize(persisted)

      {:error, reason} ->
        Logger.warning("Global pause state could not be read at #{path_for()}: #{inspect(reason)}; starting unpaused")
        @default
    end
  end

  @spec save(map()) :: :ok
  def save(%{globally_paused: paused} = state) when is_boolean(paused) do
    JsonStore.write!(path_for(), %{
      "version" => 1,
      "globally_paused" => paused,
      "paused_at" => encode_datetime(Map.get(state, :paused_at)),
      "source" => Map.get(state, :source)
    })
  rescue
    error ->
      Logger.warning("Global pause state could not be persisted at #{path_for()}: #{Exception.message(error)}")
      :ok
  end

  @spec path_for() :: Path.t()
  def path_for do
    Application.get_env(:aiur, :global_pause_store_path) ||
      Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.global-pause.json")
  end

  defp normalize(%{} = persisted) do
    paused = Map.get(persisted, "globally_paused", Map.get(persisted, :globally_paused, false)) == true
    paused_at = persisted |> Map.get("paused_at", Map.get(persisted, :paused_at)) |> decode_datetime()
    source = persisted |> Map.get("source", Map.get(persisted, :source)) |> normalize_source()

    %{globally_paused: paused, paused_at: if(paused, do: paused_at), source: if(paused, do: source)}
  end

  defp normalize(_), do: @default

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(_), do: nil

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp decode_datetime(_), do: nil

  defp normalize_source(value) when is_binary(value) and value != "", do: value
  defp normalize_source(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_source(_), do: nil
end
