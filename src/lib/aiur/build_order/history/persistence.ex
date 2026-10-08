defmodule Aiur.BuildOrder.History.Persistence do
  @moduledoc false
  require Logger
  alias Aiur.BuildOrder.History.Row
  alias Aiur.Fs
  @max_file_bytes 64_000_000

  @spec empty() :: map()
  def empty, do: %{rows: %{}, generation: 1, complete: false, status: "ok", checkpoints: %{backfill: nil, closed_since: nil}}
  @spec load(Path.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def load(path, repository) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, empty()}
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes -> load_regular(path, repository)
      {:ok, %File.Stat{type: :regular}} -> corrupt(path)
      {:ok, _stat} -> {:error, :history_unsafe_path}
      {:error, _reason} -> {:error, :state_dir_unavailable}
    end
  end

  defp load_regular(path, repository) do
    with {:ok, contents} <- File.read(path), {:ok, record} <- Jason.decode(contents) do
      case decode(record, repository) do
        {:ok, _data} = result -> result
        {:error, reason} when reason in [:version_unsupported, :repository_mismatch] -> {:error, reason}
        _ -> corrupt(path)
      end
    else
      _ -> corrupt(path)
    end
  end

  defp decode(%{"version" => version}, _repository) when is_integer(version) and version > 1, do: {:error, :version_unsupported}
  defp decode(%{"version" => 1, "repository" => other}, repository) when other != repository, do: {:error, :repository_mismatch}

  defp decode(%{"version" => 1, "repository" => _, "status" => status, "complete" => complete, "generation" => g, "checkpoints" => checkpoints, "rows" => rows}, _repository)
       when status in ["ok", "rebuilding"] and is_boolean(complete) and is_integer(g) and g > 0 and is_list(rows) do
    with true <- status != "rebuilding" or not complete, true <- valid_checkpoints?(checkpoints), {:ok, rows} <- decode_rows(rows) do
      {:ok, %{rows: rows, generation: g, status: status, complete: complete, checkpoints: %{backfill: checkpoints["backfill"], closed_since: checkpoints["closed_since"]}}}
    else
      _ -> {:error, :history_corrupt}
    end
  end

  defp decode(_record, _repository), do: {:error, :history_corrupt}

  defp decode_rows(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn json, {:ok, acc} ->
      case Row.from_json(json) do
        {:ok, row} -> if Map.has_key?(acc, row.number), do: {:halt, {:error, :duplicate_row}}, else: {:cont, {:ok, Map.put(acc, row.number, row)}}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_checkpoints?(%{"backfill" => backfill, "closed_since" => closed} = checkpoints),
    do: map_size(checkpoints) == 2 and (is_nil(backfill) or json_map?(backfill)) and (is_nil(closed) or json_map?(closed))

  defp valid_checkpoints?(_checkpoints), do: false
  @spec json_map?(term()) :: boolean()
  def json_map?(value), do: is_map(value) and json?(value)
  defp json?(value) when is_map(value), do: Enum.all?(value, fn {k, v} -> is_binary(k) and String.valid?(k) and json?(v) end)
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value), do: is_nil(value) or is_boolean(value) or is_number(value)

  defp corrupt(path) do
    case Fs.quarantine(path) do
      :ok ->
        {:error, :history_corrupt}

      {:error, reason} ->
        Logger.warning("aiur_build_history quarantine_failed reason=#{inspect(reason)}")
        {:error, :state_dir_unavailable}
    end
  end

  @spec write(map()) :: :ok | {:error, term()}
  def write(state) do
    record = %{
      version: 1,
      repository: state.repository,
      status: state.status,
      complete: state.health.complete?,
      generation: state.health.generation,
      checkpoints: state.checkpoints,
      rows: state.rows |> Map.values() |> Enum.sort_by(& &1.number) |> Enum.map(&Row.to_json/1)
    }

    with {:ok, json} <- Jason.encode(record), true <- byte_size(json) <= @max_file_bytes, :ok <- regular_path(state.path), :ok <- Fs.atomic_write(state.path, json, fsync: true, mode: 0o600) do
      if state.synced?, do: :ok, else: Fs.sync_filesystem()
    else
      false -> {:error, :record_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp regular_path(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :history_unsafe_path}
      {:error, reason} -> {:error, reason}
    end
  end
end
