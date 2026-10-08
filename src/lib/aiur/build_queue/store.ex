defmodule Aiur.BuildQueue.Store do
  @moduledoc """
  Crash-safe persistence for the versioned build queue document.

  Only a missing file starts empty. Unreadable or invalid state returns an
  error without modifying the file; the caller must stop writes until recovery.
  """

  require Logger

  alias Aiur.BuildQueue.Model
  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  @spec load() :: {:ok, Model.t()} | {:error, {:read_failed, term()}}
  def load do
    with {:ok, path} <- resolve_path(),
         {:ok, persisted} <- JsonStore.read(path, :missing),
         {:ok, document} <- decode(persisted) do
      {:ok, document}
    else
      {:error, reason} ->
        Logger.error("Build queue state could not be recovered: #{inspect(reason)}; queue writes must remain disabled")
        {:error, {:read_failed, reason}}
    end
  end

  @spec save(Model.t()) :: :ok | {:error, term()}
  def save(document) do
    case resolve_path() do
      {:ok, path} -> persist(path, document)
      {:error, reason} -> {:error, {:path_unavailable, reason}}
    end
  end

  defp persist(path, document) do
    JsonStore.write!(path, Model.encode(document))
  rescue
    error ->
      Logger.warning("Build queue state could not be persisted at #{path}: #{Exception.message(error)}")
      {:error, {:write_failed, error.__struct__, Exception.message(error)}}
  end

  defp resolve_path do
    with {:ok, directory} <- Paths.build_queue_dir() do
      {:ok, Path.join(directory, "queue.json")}
    end
  end

  defp decode(:missing), do: {:ok, @empty}
  defp decode(persisted), do: Model.decode(persisted)
end
