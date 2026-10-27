defmodule Aiur.RunTelemetry.SummaryMerge do
  @moduledoc "Merges projected chart samples while preserving full-run resource totals."

  alias Aiur.RunTelemetry.{Dataset, RetainedCache, Summaries, SummaryIndex, SummaryReader}

  @projection_budget_bytes 24 * 1024 * 1024
  # Live decode throughput is about 10 MB/s under load. Keep the cold pass
  # below five seconds while leaving room for indexing and projection work.
  @max_scan_bytes 45 * 1024 * 1024

  @doc "Loads and merges retained projections one boot at a time."
  @spec load(Path.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  @spec load(Path.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def load(file, current, opts \\ []) do
    summaries = Summaries.summary_boot_ids() |> Enum.reject(&(&1 == current))

    if summaries == [] do
      bounded_raw(file)
    else
      key = Keyword.get_lazy(opts, :cache_identity, fn -> RetainedCache.identity(current) end)
      retained = RetainedCache.fetch(__MODULE__, key, fn -> load_retained(summaries, opts) end, max_value_bytes: 24 * 1024 * 1024)

      with {:ok, dataset} <- retained, do: {:ok, merge_live(file, current, dataset)}
    end
  rescue
    _error -> {:error, :retained_unreadable}
  end

  defp merge_live(file, current, dataset) do
    case Dataset.build(file, session: :current, boot_id: current) do
      {:ok, live} -> merge([live, dataset]) |> Map.put(:retained_runs, dataset.retained_runs)
      {:error, _reason} -> dataset
    end
  end

  defp load_retained(summaries, opts) do
    {datasets, _scan_bytes, skipped_large} =
      summaries
      |> index_summaries(opts)
      |> decode_summaries(opts)

    case datasets do
      datasets when is_list(datasets) and datasets != [] ->
        case trim(datasets) do
          :unfit ->
            {:error, :retained_unreadable}

          {included, merged} ->
            {:ok,
             Map.put(merged, :retained_runs, %{
               included: length(included),
               total: length(summaries),
               skipped_large: skipped_large
             })}
        end

      _other ->
        if skipped_large > 0, do: {:error, :retained_scan_limited}, else: {:error, :retained_unreadable}
    end
  end

  defp index_summaries(summaries, opts) do
    index_loader = Keyword.get(opts, :summary_index_loader, &SummaryIndex.time_range_end/1)

    summaries
    |> Enum.reduce([], fn boot, entries ->
      case index_loader.(boot) do
        {:ok, observed_at, _tail_bytes, file_bytes} ->
          [{observed_at, boot, file_bytes} | entries]

        _other ->
          entries
      end
    end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
  end

  defp decode_summaries(entries, opts) do
    dataset_loader = Keyword.get(opts, :summary_dataset_loader, &Summaries.load_dataset/1)
    max_scan_bytes = Keyword.get(opts, :max_scan_bytes, @max_scan_bytes)

    {datasets, used_bytes, skipped_large} =
      Enum.reduce_while(entries, {[], 0, 0}, fn entry, acc ->
        decode_summary(entry, acc, dataset_loader, max_scan_bytes)
      end)

    {datasets, used_bytes, skipped_large}
  end

  defp decode_summary({_observed_at, _boot, file_bytes}, {datasets, used_bytes, skipped}, _loader, max_scan_bytes)
       when used_bytes + file_bytes > max_scan_bytes and datasets != [] do
    {:cont, {datasets, used_bytes, skipped + 1}}
  end

  defp decode_summary({_observed_at, boot, file_bytes}, {datasets, used_bytes, skipped}, loader, max_scan_bytes) do
    if used_bytes + file_bytes > max_scan_bytes do
      {:cont, {datasets, used_bytes, skipped + 1}}
    else
      load_candidate(boot, datasets, used_bytes, skipped, file_bytes, loader)
    end
  end

  defp load_candidate(boot, datasets, used_bytes, skipped, file_bytes, loader) do
    case loader.(boot) do
      {:ok, dataset} ->
        candidate = [dataset | datasets] |> Enum.sort_by(&get_in(&1, [:provenance, :time_range, :end]), :desc)

        if :erlang.external_size(candidate) <= @projection_budget_bytes,
          do: {:cont, {candidate, used_bytes + file_bytes, skipped}},
          else: {:halt, {datasets, used_bytes, skipped}}

      {:error, _reason} ->
        {:cont, {datasets, used_bytes + file_bytes, skipped}}
    end
  end

  defp trim([]), do: :unfit

  defp trim(datasets) do
    merged = merge(datasets)

    if :erlang.external_size(merged) <= @projection_budget_bytes,
      do: {datasets, merged},
      else: trim(Enum.drop(datasets, -1))
  end

  defp bounded_raw(file) do
    files = if File.dir?(file), do: Path.wildcard(Path.join(file, "**/telemetry.ndjson")), else: [file]
    size = Enum.reduce(files, 0, fn path, sum -> sum + File.stat!(path).size end)
    if files != [] and size <= 1024 * 1024, do: Dataset.build(file, []), else: {:error, :retained_unreadable}
  end

  @spec merge([map()]) :: map()
  def merge(datasets) do
    merged = Dataset.merge(datasets)
    actors = datasets |> Enum.flat_map(&Map.to_list(&1.actors)) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    merged =
      merged
      |> Map.put(:actors, Map.new(actors, fn {key, versions} -> {key, merge_actor(versions)} end))
      |> Map.update!(:provenance, &Map.put(&1, :generated_by, "presenter:cross"))

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
