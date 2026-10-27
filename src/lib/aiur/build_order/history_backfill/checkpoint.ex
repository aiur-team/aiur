defmodule Aiur.BuildOrder.HistoryBackfill.Checkpoint do
  @moduledoc false
  alias Aiur.Config.Paths
  alias Aiur.Fs

  @spec load(pos_integer(), String.t(), non_neg_integer(), keyword()) :: {:ok, map(), Path.t()} | {:error, atom()}
  def load(issue, repository, start_after, opts) do
    with {:ok, dir} <- directory(opts),
         :ok <- File.mkdir_p(dir),
         path = Path.join(dir, "#{issue}.json"),
         {:ok, checkpoint} <- read(path, issue, repository, start_after, opts) do
      {:ok, checkpoint, path}
    else
      _ -> {:error, :history_backfill_checkpoint_unavailable}
    end
  end

  defp directory(opts) do
    case Keyword.fetch(opts, :state_dir) do
      {:ok, dir} -> {:ok, dir}
      :error -> Paths.history_backfill_state_dir()
    end
  end

  defp read(path, issue, repository, start_after, opts) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, %{version: 1, repository: repository, issue: issue, cap: Keyword.fetch!(opts, :cap), handed_out: 0, cursor: start_after || 0}}
      {:ok, %{type: :regular, size: size}} when size <= 65_536 -> decode(path, issue, repository)
      _ -> {:error, :unsafe_checkpoint}
    end
  end

  defp decode(path, issue, repository) do
    with {:ok, bytes} <- File.read(path),
         {:ok, data} <- Jason.decode(bytes),
         true <- valid?(data, issue, repository) do
      {:ok, Map.new(data, fn {key, value} -> {String.to_existing_atom(key), value} end)}
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  defp valid?(%{"version" => 1, "issue" => issue, "repository" => repository, "cap" => cap, "handed_out" => count, "cursor" => cursor, "updated_at" => at} = data, issue, repository) do
    Enum.sort(Map.keys(data)) == ~w(cap cursor handed_out issue repository updated_at version) and
      valid_counters?(cap, count, cursor) and is_binary(at) and match?({:ok, _, _}, DateTime.from_iso8601(at))
  end

  defp valid?(_, _, _), do: false

  defp valid_counters?(cap, count, cursor), do: is_integer(cap) and cap > 0 and is_integer(count) and count >= 0 and count <= cap and is_integer(cursor) and cursor >= 0

  @spec save(Path.t(), map(), keyword()) :: :ok | {:error, atom()}
  def save(path, checkpoint, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    bytes = checkpoint |> Map.put(:updated_at, DateTime.to_iso8601(now)) |> Jason.encode!()
    writer = Keyword.get(opts, :writer, &Fs.atomic_write/3)

    case writer.(path, bytes, fsync: true, mode: 0o600) do
      :ok -> :ok
      _ -> {:error, :history_backfill_checkpoint_failed}
    end
  end
end
