defmodule Aiur.BuildOrder.Features.LabelStateStore do
  @moduledoc false
  require Logger
  alias Aiur.BuildOrder.Features.{FeatureData, LabelRules}
  alias Aiur.{Fs, JsonStore}
  @states ~w(pending_label labelled exempt held_backfill pending_unlabel unlabelled failed)a

  @spec load(Path.t() | nil) :: {:ok, map()} | :rebuild | {:error, term()}
  def load(nil), do: {:error, :state_dir_unavailable}

  def load(path) do
    case JsonStore.read(path, nil) do
      {:ok, nil} ->
        :rebuild

      {:ok, data} ->
        case decode(data) do
          {:ok, entries} -> {:ok, entries}
          :error -> quarantine(path)
        end

      {:error, %Jason.DecodeError{}} ->
        quarantine(path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp quarantine(path) do
    case File.rename(path, path <> ".corrupt-" <> Integer.to_string(System.os_time(:microsecond))) do
      :ok ->
        Logger.warning("feature label projection state corrupt; rebuilding")
        :rebuild

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec save(Path.t() | nil, map()) :: :ok | {:error, term()}
  def save(nil, _entries), do: {:error, :state_dir_unavailable}

  def save(path, entries) do
    records = entries |> Enum.sort() |> Enum.map(fn {{slug, n}, value} -> Map.merge(value, %{slug: slug, number: n}) end)
    with :ok <- File.mkdir_p(Path.dirname(path)), do: Fs.atomic_write(path, Jason.encode!(%{version: 1, entries: records}), fsync: true, mode: 0o600)
  end

  defp decode(%{"version" => 1, "entries" => records}) when is_list(records) do
    Enum.reduce_while(records, {:ok, %{}}, fn record, {:ok, entries} ->
      case decode_entry(record) do
        {:ok, key, value} -> decoded_entry(entries, key, value)
        :error -> {:halt, :error}
      end
    end)
  end

  defp decode(_), do: :error

  defp decoded_entry(entries, key, value) do
    if Map.has_key?(entries, key), do: {:halt, :error}, else: {:cont, {:ok, Map.put(entries, key, value)}}
  end

  defp decode_entry(%{"slug" => slug, "number" => n, "state" => state, "attempts" => attempts, "last_error" => error} = record) do
    state = Enum.find(@states, &(Atom.to_string(&1) == state))

    with true <- FeatureData.slug?(slug) and is_integer(n) and n > 0 and not is_nil(state),
         true <- is_integer(attempts) and attempts >= 0 and (is_nil(error) or is_binary(error)),
         {:ok, written} <- time(record["written_at"]),
         {:ok, seen} <- time(record["seen_at"]),
         {:ok, %DateTime{} = queued} <- time(record["queued_at"]) do
      {:ok, {slug, n},
       %{
         state: state,
         attempts: attempts,
         last_error: error,
         written_at: written,
         seen_at: seen,
         queued_at: queued,
         failed_from: Enum.find([:pending_label, :pending_unlabel], &(Atom.to_string(&1) == record["failed_from"]))
       }}
    else
      _ -> :error
    end
  end

  defp decode_entry(_), do: :error
  defp time(nil), do: {:ok, nil}

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> {:ok, time}
      _ -> :error
    end
  end

  defp time(_), do: :error

  @spec rebuild(map(), ([pos_integer()] -> tuple()), module(), keyword(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def rebuild(snapshot, read_rows, features, opts, now) do
    entries = LabelRules.reconcile_registry(%{}, snapshot.owners, now)

    with {:ok, entries} <- restore_labels(entries, read_rows), do: restore_journals(snapshot, entries, read_rows, features, opts, now)
  end

  defp restore_journals(snapshot, entries, read_rows, features, opts, now) do
    Enum.reduce_while(Map.keys(snapshot.features), {:ok, entries}, fn slug, {:ok, acc} ->
      with {:ok, events} <- features.journal(slug, opts),
           {:ok, entries} <- restore_tombstones(events, acc, snapshot.owners, read_rows, now) do
        {:cont, {:ok, entries}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp restore_labels(entries, read_rows) do
    numbers = entries |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    read_chunks(numbers, entries, read_rows, &restore_row_labels/2)
  end

  defp restore_row_labels(row, entries) do
    Enum.reduce(if(is_list(row.labels), do: row.labels, else: []), entries, &restore_label(&1, row, &2))
  end

  defp restore_label(label, row, entries) do
    with {:ok, slug} <- LabelRules.parse(label),
         %{state: state} = entry when state in [:pending_label, :held_backfill, :labelled] <- entries[{slug, row.number}] do
      Map.put(entries, {slug, row.number}, %{entry | state: :labelled, seen_at: row.observed_at})
    else
      _ -> entries
    end
  end

  defp restore_tombstones(events, entries, owners, read_rows, now) do
    latest = events |> Enum.filter(&(&1.type in ["member.added", "member.removed"])) |> Enum.reduce(%{}, &Map.put(&2, &1.number, &1))

    removed =
      Map.filter(latest, fn {n, event} ->
        event.type == "member.removed" and not String.starts_with?(event.source, "label:") and not match?(%{feature: slug} when slug == event.feature, owners[n])
      end)

    read_chunks(Map.keys(removed), entries, read_rows, fn row, acc ->
      event = removed[row.number]
      if has_label?(row, event.feature), do: Map.put(acc, {event.feature, row.number}, LabelRules.entry(:pending_unlabel, now)), else: acc
    end)
  end

  defp read_chunks(numbers, entries, read_rows, update) do
    numbers
    |> Enum.chunk_every(200)
    |> Enum.reduce_while({:ok, entries}, fn chunk, {:ok, acc} ->
      case read_rows.(chunk) do
        {:ok, rows, _health} -> {:cont, {:ok, Enum.reduce(rows, acc, update)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp has_label?(%{labels: labels}, slug) when is_list(labels), do: ("feature:" <> slug) in labels
  defp has_label?(_, _), do: false
end
