defmodule Aiur.Experiments.Checkpoint do
  @moduledoc false
  alias Aiur.Experiments.{Journal, Paths, Persistence, Reader, Schema, Snapshot, WindowData}

  @spec safe_run(String.t(), DateTime.t(), map()) :: {:ok, map()} | {:error, term()}
  def safe_run(id, now, context) do
    result = protected_run(id, now, context)
    error_record(id, now, result)
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
    with {:ok, plan} <- prepare(id, now, context), do: commit(plan)
  end

  @spec prepare(String.t(), DateTime.t(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(id, now, context) do
    with {:ok, spec, _read_only?} <- Reader.spec(id) do
      plan = %{id: id, spec: spec, now: now, context: Map.put(context, :clock, fn -> now end)}
      if spec["status"] == "active", do: prepare_active(plan), else: {:ok, Map.put(plan, :skipped, true)}
    end
  end

  defp prepare_active(plan) do
    name = if plan.spec["design"]["kind"] == "before_after", do: "after", else: "observation"
    window = plan.spec["windows"][name]

    with {:ok, before} <- prepare_before(plan),
         {:ok, snapshot} <- latest(plan.id, name, plan.context) do
      plan = Map.merge(plan, %{before: before, name: name})

      if snapshot || not reached?(plan.now, window["start"]) || plan.now == timestamp(window["start"]) do
        {:ok, Map.put(plan, :skip_window, true)}
      else
        prepare_window(plan)
      end
    end
  end

  defp prepare_before(%{spec: %{"design" => %{"kind" => "before_after"}}} = plan) do
    with {:ok, old} <- latest(plan.id, "before", plan.context) do
      if old && reached?(plan.now, plan.spec["design"]["change"]["time"]) && earlier?(old["window"]["end"], plan.spec["windows"]["before"]["end"]) do
        prepare_snapshot(plan, "before", old, nil, "change_time_reached")
      else
        {:ok, nil}
      end
    end
  end

  defp prepare_before(_plan), do: {:ok, nil}

  defp prepare_window(plan) do
    with {:ok, entries} <- Journal.read(Paths.file(plan.id, "journal.ndjson")) do
      if Enum.any?(entries, &(&1["kind"] == "checkpoint_limit_reached" && &1["window"] == plan.name)) do
        {:ok, Map.put(plan, :limit, true)}
      else
        evaluate_window(plan)
      end
    end
  end

  defp evaluate_window(plan) do
    evaluate = Map.get(plan.context, :checkpoint_evaluate, &WindowData.evaluate/3)

    # ponytail: scan full windows until interval sources can retain duration starts across slices.
    with {:ok, existing} <- partial(plan.id, plan.name),
         {:ok, data} <- evaluate.(plan.spec, plan.name, Map.put(plan.context, :checkpoint_partial, existing)) do
      entries = new_entries(data.metrics, existing)
      cap = settings_limit(plan.context)
      observations = Enum.sum(for {_ref, metric} <- data.metrics, do: length(metric["observations"]))
      limit = length(existing) + length(entries) > cap || observations > cap
      plan = Map.merge(plan, %{data: data, existing: existing, entries: entries, limit: limit})

      prepare_final(plan)
    end
  end

  defp prepare_final(plan) do
    if reached?(plan.now, plan.spec["windows"][plan.name]["end"]) && not plan.limit do
      with {:ok, final} <- prepare_snapshot(plan, plan.name, nil, plan.data, nil), do: {:ok, Map.put(plan, :final, final)}
    else
      {:ok, Map.put(plan, :final, nil)}
    end
  end

  defp prepare_snapshot(plan, name, old, data, reason) do
    opts = [now: plan.now, context: plan.context, reason: reason]

    if Map.has_key?(plan.context, :checkpoint_freeze) do
      {:ok, %{legacy: plan.context.checkpoint_freeze, id: plan.id, name: name, opts: opts}}
    else
      with {:ok, data} <- evaluated_data(plan, name, data),
           {:ok, snapshot} <- Snapshot.prepare_spec(plan.spec, name, old, data, opts) do
        {:ok, %{id: plan.id, spec: plan.spec, name: name, old: old, snapshot: snapshot, opts: opts}}
      end
    end
  end

  defp evaluated_data(_plan, _name, data) when is_map(data), do: {:ok, data}
  defp evaluated_data(plan, name, nil), do: WindowData.evaluate(plan.spec, name, plan.context)

  @spec commit(map()) :: {:ok, map()} | {:error, term()}
  def commit(%{skipped: true}), do: {:ok, %{skipped: true}}

  def commit(plan) do
    with :ok <- Snapshot.unchanged_spec(plan.id, plan.spec),
         :ok <- Persistence.writable(plan.id),
         :ok <- commit_snapshot(plan.before) do
      commit_window(plan)
    end
  end

  defp commit_window(%{skip_window: true}), do: {:ok, %{appended: 0}}

  defp commit_window(%{limit: true} = plan) do
    with :ok <- record_limit(plan), do: {:ok, %{appended: 0, limit_reached: true}}
  end

  defp commit_window(plan) do
    with :ok <- append_entries(plan.id, plan.name, plan.entries),
         :ok <-
           Persistence.write_json(Paths.file(plan.id, "snapshots/#{plan.name}.checkpoint.json"), %{
             "schema_version" => Schema.current(),
             "last_checkpoint_at" => DateTime.to_iso8601(plan.now),
             "window" => plan.data.window
           }),
         :ok <- commit_snapshot(plan.final) do
      {:ok, %{appended: length(plan.entries)}}
    end
  end

  defp commit_snapshot(nil), do: :ok
  defp commit_snapshot(%{legacy: callback, id: id, name: name, opts: opts}), do: callback.(id, name, opts) |> frozen_result()
  defp commit_snapshot(prepared), do: Snapshot.commit_prepared(prepared) |> frozen_result()
  defp frozen_result({:ok, _snapshot}), do: :ok
  defp frozen_result(error), do: error

  @spec partial(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def partial(id, name) do
    with {:ok, rows} <- Journal.read(Paths.file(id, "snapshots/#{name}.partial.ndjson")),
         :ok <- check_versions(rows) do
      {:ok, rows}
    end
  end

  defp check_versions(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case Schema.migrate(row) do
        {:ok, _row} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
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

    with :ok <- Aiur.Journal.prepare(directory, path), do: Journal.append_many(path, entries)
  end

  defp settings_limit(context) do
    Map.get_lazy(context, :max_snapshot_observations, fn ->
      case Aiur.Config.settings() do
        {:ok, %{experiments: config}} -> config.max_snapshot_observations
        _ -> 50_000
      end
    end)
  end

  defp record_limit(plan) do
    path = Paths.file(plan.id, "journal.ndjson")

    with {:ok, entries} <- Journal.read(path) do
      if Enum.any?(entries, &(&1["kind"] == "checkpoint_limit_reached" && &1["window"] == plan.name)) do
        :ok
      else
        Journal.append(path, %{
          "schema_version" => Schema.current(),
          "kind" => "checkpoint_limit_reached",
          "window" => plan.name,
          "at" => DateTime.to_iso8601(plan.now),
          "limit" => settings_limit(plan.context)
        })
      end
    end
  end

  defp latest(id, name, context), do: Map.get(context, :checkpoint_latest, &Snapshot.latest/2).(id, name)
  defp reached?(_now, nil), do: false
  defp reached?(now, at), do: DateTime.compare(now, timestamp(at)) != :lt
  defp earlier?(left, right), do: DateTime.compare(timestamp(left), timestamp(right)) == :lt
  defp timestamp(at), do: at |> DateTime.from_iso8601() |> elem(1)

  @spec error_record(String.t(), DateTime.t(), term()) :: term()
  def error_record(id, now, {:error, reason}) do
    if Paths.valid_id?(id), do: record_failure(id, now, reason), else: :ok
  end

  def error_record(_id, _now, _result), do: :ok

  defp record_failure(id, now, reason) do
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
