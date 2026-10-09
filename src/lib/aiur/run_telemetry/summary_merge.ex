defmodule Aiur.RunTelemetry.SummaryMerge do
  @moduledoc "Merges projected chart samples while preserving full-run resource totals."

  alias Aiur.RunTelemetry.{Dataset, Summaries, SummaryReader}

  @doc "Loads and merges retained projections one boot at a time."
  @spec load(Path.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def load(file, current) do
    summaries = Summaries.summary_boot_ids() |> Enum.reject(&(&1 == current))
    if summaries == [], do: bounded_raw(file), else: load_retained(summaries, live(file, current))
  rescue
    _error -> {:error, :retained_unreadable}
  end

  defp live(file, current) do
    case Dataset.build(file, session: :current, boot_id: current) do
      {:ok, dataset} -> [dataset]
      {:error, _reason} -> []
    end
  end

  defp load_retained(summaries, live) do
    {merged, readable?} = Enum.reduce_while(summaries, {live, false}, &merge_retained/2)

    case {readable?, merged} do
      {true, [dataset]} -> {:ok, dataset}
      _other -> {:error, :retained_unreadable}
    end
  rescue
    _error -> {:error, :retained_unreadable}
  end

  defp bounded_raw(file) do
    files = if File.dir?(file), do: Path.wildcard(Path.join(file, "**/telemetry.ndjson")), else: [file]
    size = Enum.reduce(files, 0, fn path, sum -> sum + File.stat!(path).size end)
    if files != [] and size <= 1024 * 1024, do: Dataset.build(file, []), else: {:error, :retained_unreadable}
  end

  defp merge_retained(boot, {acc, _readable?}) do
    case Summaries.load_dataset(boot) do
      {:ok, dataset} -> {:cont, {[merge([dataset | acc])], true}}
      {:error, _reason} -> {:halt, {[], false}}
    end
  end

  @spec merge([map()]) :: map()
  def merge(datasets) do
    merged = Dataset.merge(datasets)
    if :erlang.external_size(merged) > 24 * 1024 * 1024, do: raise(ArgumentError, "oversized retained rollup")
    actors = datasets |> Enum.flat_map(&Map.to_list(&1.actors)) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    merged =
      merged
      |> Map.put(:actors, Map.new(actors, fn {key, versions} -> {key, merge_actor(versions)} end))
      |> Map.update!(:provenance, &Map.put(&1, :generated_by, "presenter:cross"))

    if :erlang.external_size(merged) > 24 * 1024 * 1024, do: raise(ArgumentError, "oversized retained rollup")
    merged
  end

  defp merge_actor(versions) do
    samples = versions |> Enum.flat_map(& &1.samples) |> Enum.uniq_by(& &1.record_id) |> Enum.sort_by(& &1.timestamp_ms) |> SummaryReader.sample()
    profiles = versions |> Enum.flat_map(&Map.to_list(&1.profile)) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    profile = Map.new(profiles, fn {metric, stats} -> {metric, merge_stats(stats)} end)
    Map.merge(hd(versions), %{samples: samples, profile: profile})
  end

  defp merge_stats(stats) do
    count = Enum.sum(Enum.map(stats, &(&1.count || 0)))
    total = Enum.sum(Enum.map(stats, &((&1.mean || 0) * (&1.count || 0))))

    %{
      count: count,
      mean: if(count > 0, do: total / count, else: nil),
      min: extreme(stats, :min, &Enum.min/1),
      max: extreme(stats, :max, &Enum.max/1),
      median: nil,
      p95: nil
    }
  end

  defp extreme(stats, key, reduce) do
    case stats |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1) do
      [] -> nil
      values -> reduce.(values)
    end
  end
end
