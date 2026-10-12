defmodule Aiur.Experiments.Checkpoint do
  @moduledoc false
  alias Aiur.Experiments.{Journal, Paths, Persistence, Reader, Schema, Snapshot, WindowData}

  @spec safe_run(String.t(), DateTime.t(), map()) :: {:ok, map()} | {:error, term()}
  def safe_run(id, now, context) do
    result = protected_run(id, now, context)
    if Paths.valid_id?(id) && match?({:error, _reason}, result), do: record_failure(id, now, result)
    result
  end

  defp protected_run(id, now, context) do
    run(id, now, context)
  rescue
    error -> {:error, {:checkpoint_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:checkpoint_caught, kind, reason}}
  end

  @spec run(String.t(), DateTime.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(id, now, context) do
    with {:ok, spec, _read_only?} <- Reader.spec(id), do: checkpoint_spec(id, spec, now, context)
  end

  defp checkpoint_spec(id, %{"status" => "active"} = spec, now, context) do
    with :ok <- Persistence.writable(id), :ok <- refreeze_before(id, spec, now, context) do
      checkpoint_window(id, spec, now, context)
    end
  end

  defp checkpoint_spec(_id, _spec, _now, _context), do: {:ok, %{skipped: true}}

  @spec partial(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def partial(id, name) do
    path = Paths.file(id, "snapshots/#{name}.partial.ndjson")
    with :ok <- Journal.writable(path), do: Journal.read(path)
  end

  defp refreeze_before(id, %{"design" => %{"kind" => "before_after"}} = spec, now, context) do
    with {:ok, snapshot} <- latest(id, "before", context) do
      if snapshot && reached?(now, spec["design"]["change"]["time"]) && earlier?(snapshot["window"]["end"], spec["windows"]["before"]["end"]) do
        freeze(id, "before", now, context, "change_time_reached") |> frozen_result()
      else
        :ok
      end
    end
  end

  defp refreeze_before(_id, _spec, _now, _context), do: :ok

  defp checkpoint_window(id, spec, now, context) do
    name = if spec["design"]["kind"] == "before_after", do: "after", else: "observation"
    window = spec["windows"][name]

    with {:ok, snapshot} <- latest(id, name, context) do
      if snapshot || not reached?(now, window["start"]) || now == timestamp(window["start"]) do
        {:ok, %{appended: 0}}
      else
        append_window(id, name, spec, now, context)
      end
    end
  end

  defp append_window(id, name, spec, now, context) do
    evaluate = Map.get(context, :checkpoint_evaluate, &WindowData.evaluate/3)
    context = Map.put(context, :clock, fn -> now end)

    # ponytail: scan full windows until interval sources can retain duration starts across slices.
    with {:ok, data} <- evaluate.(spec, name, context),
         {:ok, existing} <- partial(id, name),
         entries = new_entries(data.metrics, existing),
         :ok <- append_entries(id, name, entries),
         :ok <-
           Persistence.write_json(Paths.file(id, "snapshots/#{name}.checkpoint.json"), %{
             "schema_version" => Schema.current(),
             "last_checkpoint_at" => DateTime.to_iso8601(now),
             "window" => data.window
           }),
         :ok <- freeze_closed(id, name, spec, now, context) do
      {:ok, %{appended: length(entries)}}
    end
  end

  defp new_entries(metrics, existing) do
    known = MapSet.new(existing, &{&1["metric"], &1["observation"]["unit_id"]})

    metrics
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {ref, metric} ->
      for row <- metric["observations"], finished?(row), not MapSet.member?(known, {ref, row["unit_id"]}) do
        %{"schema_version" => Schema.current(), "metric" => ref, "observation" => row}
      end
    end)
    |> Enum.uniq_by(&{&1["metric"], &1["observation"]["unit_id"]})
  end

  defp finished?(row), do: row["censored"] != true && not is_nil(Map.get(row, "finished_at", row["at"]))

  defp append_entries(id, name, entries) do
    directory = Paths.file(id, "snapshots")
    path = Paths.file(id, "snapshots/#{name}.partial.ndjson")

    with :ok <- Aiur.Journal.ensure_directory(directory),
         :ok <- Aiur.Journal.prepare(directory, path) do
      Enum.reduce_while(entries, :ok, &append_entry(path, &1, &2))
    end
  end

  defp append_entry(path, entry, :ok) do
    case Journal.append(path, entry) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp frozen_result({:ok, _snapshot}), do: :ok
  defp frozen_result(error), do: error

  defp freeze_closed(id, name, spec, now, context) do
    if reached?(now, spec["windows"][name]["end"]) do
      freeze(id, name, now, context, nil) |> frozen_result()
    else
      :ok
    end
  end

  defp freeze(id, name, now, context, reason) do
    callback = Map.get(context, :checkpoint_freeze, &Snapshot.freeze/3)
    callback.(id, name, now: now, context: context, reason: reason)
  end

  defp latest(id, name, context), do: Map.get(context, :checkpoint_latest, &Snapshot.latest/2).(id, name)
  defp reached?(_now, nil), do: false
  defp reached?(now, at), do: DateTime.compare(now, timestamp(at)) != :lt
  defp earlier?(left, right), do: DateTime.compare(timestamp(left), timestamp(right)) == :lt
  defp timestamp(at), do: at |> DateTime.from_iso8601() |> elem(1)

  defp record_failure(id, now, {:error, reason}) do
    path = Paths.file(id, "journal.ndjson")

    with {:ok, entries} <- Journal.read(path) do
      recent? = Enum.any?(entries, &(&1["kind"] == "checkpoint_failed" && DateTime.diff(now, timestamp(&1["at"]), :second) < 3_600))

      unless recent? do
        Journal.append(path, %{"schema_version" => Schema.current(), "kind" => "checkpoint_failed", "at" => DateTime.to_iso8601(now), "reason" => inspect(reason)})
      end
    end
  rescue
    _error -> :ok
  end
end
