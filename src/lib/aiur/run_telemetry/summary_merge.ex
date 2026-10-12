defmodule Aiur.RunTelemetry.SummaryMerge do
  @moduledoc "Merges projected chart samples while preserving full-run resource totals."

  alias Aiur.RunTelemetry.{Dataset, RetainedCache, Summaries, SummaryReader}

  @doc "Loads and merges retained projections one boot at a time."
  @spec load(Path.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def load(file, current) do
    summaries = Summaries.summary_boot_ids() |> Enum.reject(&(&1 == current))

    if summaries == [] do
      bounded_raw(file)
    else
      key = RetainedCache.identity(current)
      retained = RetainedCache.fetch(__MODULE__, key, fn -> load_retained(summaries) end, max_value_bytes: 24 * 1024 * 1024)

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

  defp load_retained(summaries) do
    result =
      Enum.reduce_while(summaries, [], fn boot, acc ->
        case Summaries.load_dataset(boot) do
          {:ok, dataset} -> {:cont, fit([dataset | acc])}
          {:error, _reason} -> {:halt, :unreadable}
        end
      end)

    case result do
      datasets when is_list(datasets) and datasets != [] ->
        case trim(datasets) do
          [] -> {:error, :retained_unreadable}
          included -> {:ok, merge(included) |> Map.put(:retained_runs, %{included: length(included), total: length(summaries)})}
        end

      _other ->
        {:error, :retained_unreadable}
    end
  end

  # ponytail: keep newest complete runs within the projection budget; expand to pre-aggregated lifecycle storage if history must be exhaustive.
  defp fit(datasets) do
    sorted = Enum.sort_by(datasets, &get_in(&1, [:provenance, :time_range, :end]), :desc)
    trim_inputs(sorted)
  end

  defp trim_inputs([]), do: []

  defp trim_inputs(datasets) do
    if :erlang.external_size(datasets) <= 24 * 1024 * 1024, do: datasets, else: trim_inputs(Enum.drop(datasets, -1))
  end

  defp trim([]), do: []

  defp trim(datasets) do
    if :erlang.external_size(merge(datasets)) <= 24 * 1024 * 1024,
      do: datasets,
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
