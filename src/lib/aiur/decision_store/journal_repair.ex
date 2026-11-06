defmodule Aiur.DecisionStore.JournalRepair do
  @moduledoc """
  Operator recovery for a Decision journal that replay found corrupt (#7577).

  Replay stops at the first record that fails validation and latches the store
  read-only. Repair checks every record on its own, then folds the survivors
  in order; a record that fails either check is quarantined. Quarantined lines
  are written byte-for-byte to a sibling `decisions.quarantine-<UTC>.ndjson`
  before the journal is atomically rewritten with the records that remain, so
  the original content is always recoverable from the two files.
  """

  alias Aiur.{DecisionProjection, Fs, Journal}
  alias Aiur.DecisionStore.{Boot, Persistence}

  @type quarantined :: %{line: pos_integer(), reason: term()}
  @type report :: %{kept: non_neg_integer(), quarantined: [quarantined()], quarantine_path: Path.t() | nil}

  @doc "Store-side call: repairs the journal, then replays it in place so the store can write again."
  @spec handle_call(map()) :: {:reply, {:ok, map()} | {:error, term()}, map()} | {:reply, {:ok, map()}, map(), {:continue, term()}}
  def handle_call(%{health: {:unavailable, _reason}} = state), do: {:reply, {:error, {:store_unavailable, state.health}}, state}

  def handle_call(state) do
    case repair(state.ndjson_path) do
      {:ok, %{quarantined: []} = report} when state.writable? ->
        {:reply, {:ok, Map.put(report, :health, state.health)}, state}

      {:ok, report} ->
        reloaded =
          state
          |> Map.merge(Boot.boot(Path.dirname(state.ndjson_path), &Fs.sync_filesystem/0))
          |> Persistence.repair_projection()

        {:reply, {:ok, Map.put(report, :health, reloaded.health)}, reloaded, {:continue, :schedule_reconciliation}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec repair(Path.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def repair(path, opts \\ []) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, content} <- File.read(path) do
      {kept, bad} = content |> lines() |> Enum.with_index(1) |> Enum.map(&decode/1) |> Enum.split_with(&match?({:ok, _, _}, &1))
      {kept, bad} = fold(kept, Enum.map(bad, fn {:error, line, reason, raw} -> {line, reason, raw} end))
      write(path, kept, Enum.sort_by(bad, &elem(&1, 0)), Keyword.get(opts, :now, DateTime.utc_now()))
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_regular_file, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lines(content) do
    case String.split(content, "\n") do
      [""] -> []
      parts -> if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    end
  end

  defp decode({raw, line}) do
    with {:ok, decoded} <- Jason.decode(raw),
         {:ok, record} <- DecisionProjection.decode_record(decoded) do
      {:ok, line, {record, raw}}
    else
      {:error, %Jason.DecodeError{}} -> {:error, line, :invalid_json, raw}
      {:error, reason} -> {:error, line, reason, raw}
    end
  end

  # Records that decode can still break the fold (an answer whose request was
  # quarantined, a duplicate event id). Quarantine the first offender and refold.
  defp fold(kept, bad) do
    case DecisionProjection.reduce_checked(Enum.map(kept, fn {:ok, _line, {record, _raw}} -> record end)) do
      {_projection, nil} ->
        {kept, bad}

      {_projection, {:corrupt, index, reason}} ->
        {:ok, line, {_record, raw}} = Enum.at(kept, index - 1)
        fold(List.delete_at(kept, index - 1), [{line, reason, raw} | bad])
    end
  end

  defp write(_path, kept, [], _now), do: {:ok, %{kept: length(kept), quarantined: [], quarantine_path: nil}}

  defp write(path, kept, bad, now) do
    stamp = now |> DateTime.truncate(:second) |> DateTime.to_iso8601(:basic)
    quarantine_path = Path.join(Path.dirname(path), "decisions.quarantine-#{stamp}.ndjson")

    # The quarantine copy is durable before the journal drops those lines.
    with :ok <- Fs.atomic_write(quarantine_path, Enum.map(bad, &[elem(&1, 2), "\n"]), fsync: true, mode: 0o600),
         :ok <- Journal.rewrite(path, Enum.map(kept, fn {:ok, _line, {_record, raw}} -> [raw, "\n"] end)) do
      {:ok,
       %{
         kept: length(kept),
         quarantined: Enum.map(bad, fn {line, reason, _raw} -> %{line: line, reason: reason} end),
         quarantine_path: quarantine_path
       }}
    end
  end
end
