defmodule Aiur.BuildOrder.EpicOverrides.Journal do
  @moduledoc false
  alias Aiur.BuildOrder.EpicOverrides.Override

  @spec load(Path.t(), String.t(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def load(path, repository, max_bytes) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, %{entries: [], overrides: %{}, generation: 0}}

      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes ->
        read(path, repository)

      _ ->
        {:error, :epic_overrides_unsafe_path}
    end
  end

  defp read(path, repository) do
    with {:ok, bytes} <- File.read(path), {:ok, record} <- Jason.decode(bytes) do
      decode(record, repository)
    else
      _ -> {:error, :epic_overrides_corrupt}
    end
  end

  defp decode(%{"version" => v}, _repo) when is_integer(v) and v > 1,
    do: {:error, :epic_overrides_version_unsupported}

  defp decode(%{"version" => 1, "repository" => r}, repo) when r != repo,
    do: {:error, :epic_overrides_repository_mismatch}

  defp decode(
         %{"version" => 1, "repository" => _, "next_seq" => next, "entries" => entries},
         _repo
       )
       when is_list(entries) and is_integer(next) and next > 0 do
    with {:ok, folded} <-
           Enum.reduce_while(entries, {:ok, %{overrides: %{}, generation: 0}}, &fold/2),
         true <- next == folded.generation + 1 do
      {:ok, Map.put(folded, :entries, entries)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :epic_overrides_corrupt}
    end
  end

  defp decode(_record, _repo), do: {:error, :epic_overrides_corrupt}

  defp fold(raw, {:ok, acc}) do
    with {:ok, entry} <- Override.from_entry(raw), true <- entry.seq == acc.generation + 1 do
      overrides =
        if entry.op == "set",
          do: Map.put(acc.overrides, entry.number, entry.value),
          else: Map.delete(acc.overrides, entry.number)

      {:cont, {:ok, %{overrides: overrides, generation: entry.seq}}}
    else
      {:error, _reason} = error -> {:halt, error}
      _ -> {:halt, {:error, :epic_overrides_corrupt}}
    end
  end

  @spec write(map()) :: :ok | {:error, term()}
  def write(state) do
    record = %{
      version: 1,
      repository: state.repository,
      next_seq: state.generation + 1,
      entries: state.entries
    }

    with {:ok, json} <- Jason.encode(record),
         true <- byte_size(json) <= state.max_bytes,
         :ok <- regular_path(state.path) do
      with :ok <- state.writer.(state.path, json, fsync: true, mode: 0o600) do
        sync_creation(state)
      end
    else
      false -> {:error, :epic_overrides_full}
      {:error, _reason} = error -> error
    end
  end

  defp sync_creation(%{synced?: true}), do: :ok

  defp sync_creation(state) do
    case state.sync.() do
      :ok -> :ok
      {:error, reason} -> {:error, {:durability_unknown, reason}}
    end
  end

  defp regular_path(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> :ok
      _ -> {:error, :epic_overrides_unsafe_path}
    end
  end
end
