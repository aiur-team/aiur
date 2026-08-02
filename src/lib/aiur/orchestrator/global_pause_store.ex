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

  @spec load() ::
          {:ok, %{globally_paused: boolean(), paused_at: DateTime.t() | nil, source: String.t() | nil}}
          | {:error, term()}
  def load do
    case JsonStore.read(path_for(), :missing) do
      {:ok, :missing} ->
        {:ok, @default}

      {:ok, persisted} ->
        case normalize(persisted) do
          {:ok, state} -> {:ok, state}
          {:error, reason} -> read_failed(reason)
        end

      {:error, reason} ->
        read_failed(reason)
    end
  end

  defp read_failed(reason) do
    Logger.error("Global pause state could not be recovered at #{path_for()}: #{inspect(reason)}; holding the daemon globally paused")
    {:error, {:read_failed, reason}}
  end

  @spec save(map()) :: :ok | {:error, term()}
  def save(%{globally_paused: paused} = state) when is_boolean(paused) do
    payload = %{
      "version" => 1,
      "globally_paused" => paused,
      "paused_at" => encode_datetime(Map.get(state, :paused_at)),
      "source" => Map.get(state, :source)
    }

    JsonStore.write!(path_for(), payload)
    :ok
  rescue
    error ->
      reason = {:write_failed, error.__struct__, Exception.message(error)}
      Logger.warning("Global pause state could not be persisted at #{path_for()}: #{Exception.message(error)}")
      {:error, reason}
  end

  @spec path_for() :: Path.t()
  def path_for do
    Application.get_env(:aiur, :global_pause_store_path) ||
      Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.global-pause.json")
  end

  defp normalize(%{} = persisted) do
    with {:ok, paused} <- fetch_boolean(persisted, "globally_paused", :globally_paused),
         {:ok, paused_at} <- fetch_datetime(persisted, "paused_at", :paused_at),
         {:ok, source} <- fetch_source(persisted, "source", :source) do
      {:ok, %{globally_paused: paused, paused_at: if(paused, do: paused_at), source: if(paused, do: source)}}
    end
  end

  defp normalize(_), do: {:error, :invalid_shape}

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(_), do: nil

  defp fetch_boolean(persisted, string_key, atom_key) do
    case Map.fetch(persisted, string_key) do
      {:ok, value} when is_boolean(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, string_key}}

      :error ->
        case Map.fetch(persisted, atom_key) do
          {:ok, value} when is_boolean(value) -> {:ok, value}
          {:ok, _value} -> {:error, {:invalid_field, atom_key}}
          :error -> {:error, {:missing_field, string_key}}
        end
    end
  end

  defp fetch_datetime(persisted, string_key, atom_key) do
    persisted |> Map.get(string_key, Map.get(persisted, atom_key)) |> decode_datetime()
  end

  defp fetch_source(persisted, string_key, atom_key) do
    persisted |> Map.get(string_key, Map.get(persisted, atom_key)) |> normalize_source()
  end

  defp decode_datetime(nil), do: {:ok, nil}

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_paused_at}
    end
  end

  defp decode_datetime(_), do: {:error, :invalid_paused_at}

  defp normalize_source(nil), do: {:ok, nil}
  defp normalize_source(value) when is_binary(value) and value != "", do: {:ok, value}
  defp normalize_source(_), do: {:error, :invalid_source}
end
