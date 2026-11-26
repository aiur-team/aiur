defmodule Aiur.Experiments.WindowData do
  @moduledoc false
  alias Aiur.Experiments.{Checkpoint, Evaluator, Snapshot}
  alias Aiur.Experiments.Sources.Common

  @spec read(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def read(spec, name, ctx \\ %{}) do
    with {:ok, snapshot} <- Snapshot.latest(spec["id"], name) do
      if snapshot, do: frozen(spec, name, snapshot, ctx), else: live(spec, name, ctx)
    end
  end

  defp frozen(spec, name, snapshot, ctx) do
    with {:ok, requested} <- window(spec, name, ctx) do
      if DateTime.compare(Common.timestamp(requested["end"]), Common.timestamp(snapshot["window"]["end"])) == :gt do
        extend_snapshot(spec, name, snapshot, ctx)
      else
        {:ok, %{metrics: snapshot["metrics"], source: :frozen}}
      end
    end
  end

  defp extend_snapshot(spec, name, snapshot, ctx) do
    with {:ok, data} <- evaluate(spec, name, ctx), do: {:ok, %{metrics: merge_frozen(snapshot, data.metrics), source: :mixed}}
  end

  defp merge_frozen(snapshot, live) do
    Map.new(snapshot["metrics"], fn {ref, frozen} ->
      finish = Common.timestamp(snapshot["window"]["end"])
      added = Enum.filter(live[ref]["observations"], &(DateTime.compare(Common.timestamp(&1["started_at"]), finish) != :lt))
      rows = (frozen["observations"] ++ added) |> Enum.uniq_by(& &1["unit_id"]) |> Enum.sort_by(& &1["unit_id"])
      {ref, Map.put(frozen, "observations", rows)}
    end)
  end

  defp live(spec, name, ctx) do
    with {:ok, partial} <- partial(spec["id"], name, ctx), {:ok, data} <- evaluate(spec, name, Map.put(ctx, :checkpoint_partial, partial)) do
      {:ok, Map.put(data, :source, if(partial == [], do: :live, else: :checkpoint))}
    end
  end

  @spec evaluate(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def evaluate(spec, name, ctx \\ %{}) do
    with {:ok, window} <- window(spec, name, ctx),
         {:ok, partial} <- partial(spec["id"], name, ctx) do
      refs = Enum.map(spec["metrics"], & &1["ref"])
      evaluate = Map.get(ctx, :evaluate, &Evaluator.observations/3)
      metrics = evaluate.(refs, window, interval_context(spec, window, ctx)) |> Aiur.JSONSafe.normalize()
      metrics = Map.new(metrics, fn {ref, result} -> {ref, normalize_result(ref, result, partial)} end)
      {:ok, %{metrics: metrics, window: window}}
    end
  end

  defp interval_context(spec, _window, ctx) do
    now = Map.get(ctx, :clock, &DateTime.utc_now/0)
    now = if is_function(now, 0), do: now.(), else: Common.timestamp(now)
    start = spec["windows"] |> Map.values() |> Enum.map(&Common.timestamp(&1["start"])) |> Enum.min(DateTime)

    ctx
    |> Map.put(:include_open, true)
    |> Map.put(:assign_by, spec["design"]["assign_by"] || "start")
    |> Map.put(:interval_window, %{start: start, end: now})
  end

  @spec window(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def window(spec, name, ctx) do
    now = Map.get(ctx, :clock, &DateTime.utc_now/0)
    now = if is_function(now, 0), do: now.(), else: Common.timestamp(now)

    case spec["windows"][name] do
      nil ->
        {:error, :invalid_window}

      window ->
        finish = Common.timestamp(window["end"]) || now
        finish = if DateTime.compare(finish, now) == :gt, do: now, else: finish
        {:ok, %{"start" => window["start"], "end" => DateTime.to_iso8601(finish)}}
    end
  end

  defp partial(id, name, ctx) do
    case Map.fetch(ctx, :checkpoint_partial) do
      {:ok, rows} -> {:ok, rows}
      :error -> Checkpoint.partial(id, name)
    end
  end

  defp normalize_result(ref, result, partial) do
    saved = for entry <- partial, entry["metric"] == ref, do: entry["observation"]
    rows = (saved ++ result["observations"]) |> Enum.map(&normalize_row/1) |> Enum.uniq_by(& &1["unit_id"]) |> Enum.sort_by(& &1["unit_id"])
    Map.put(result, "observations", rows)
  end

  defp normalize_row(row) do
    row
    |> Map.put("started_at", row["started_at"] || row["at"])
    |> Map.put("finished_at", if(row["censored"], do: nil, else: row["finished_at"] || row["at"]))
    |> Map.put_new("censored", false)
  end
end
