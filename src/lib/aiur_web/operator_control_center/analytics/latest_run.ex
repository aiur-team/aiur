defmodule AiurWeb.OperatorControlCenter.Analytics.LatestRun do
  @moduledoc """
  Selects the newest analyzable dataset for the Analytics latest-run view.

  A daemon restart moves live telemetry to a fresh log root. Until that stream
  records agent or ticket activity, the newest materialized prior run remains
  the truthful latest analyzable dataset.

  Only the newest analyzable prior summary is retained in a bounded cache.
  A persistent cache owner serializes cold loads and survives request exits.
  Per-summary file metadata invalidates regenerated summaries without retaining
  every decoded boot.

  When no retained summary fits the cold scan budget, `load/4` returns
  `{:error, :retained_scan_limited}`. If summaries fit but none can be decoded,
  it returns `{:error, :retained_unreadable}` instead of the empty live fallback.
  """

  alias Aiur.RunTelemetry.{Dataset, Summaries, SummaryIndex}

  alias Aiur.RunTelemetry.RetainedCache

  @max_scan_bytes 45 * 1024 * 1024

  @spec load(Path.t(), String.t() | nil, (map() -> boolean())) ::
          {:ok, map()} | {:error, term()}
  @spec load(Path.t(), String.t() | nil, (map() -> boolean()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def load(file, current_boot, analyzable?, opts \\ []) when is_function(analyzable?, 1) do
    live = Dataset.build(file, session: :current, boot_id: current_boot)

    case live do
      {:ok, dataset} ->
        if analyzable?.(dataset), do: live, else: latest_prior(current_boot, live, analyzable?, opts)

      {:error, _reason} ->
        latest_prior(current_boot, live, analyzable?, opts)
    end
  end

  # The newest analyzable prior summary wins. When retained summaries exist but
  # none of them decode, that is a persistence failure the page must surface,
  # not an idle fleet to paper over.
  defp latest_prior(current_boot, fallback, analyzable?, opts) do
    {datasets, unreadable?} = prior_datasets(opts, current_boot, analyzable?)

    case newest_analyzable(datasets, analyzable?) do
      {:ok, dataset} -> {:ok, dataset}
      :none when unreadable? == :scan_limited -> {:error, :retained_scan_limited}
      :none when unreadable? -> {:error, :retained_unreadable}
      :none -> fallback
    end
  end

  defp newest_analyzable(datasets, analyzable?) do
    datasets
    |> Enum.filter(analyzable?)
    |> Enum.max_by(&observed_at/1, &>=/2, fn -> nil end)
    |> case do
      nil -> :none
      dataset -> {:ok, dataset}
    end
  end

  # ---- decoded-summary cache ----

  # `prior_loader/0` returns `{datasets, unreadable?}` so tests can inject both
  # halves; the default reads the real summaries through `Summaries`.
  defp prior_datasets(opts, current_boot, analyzable?) do
    identity = Keyword.get_lazy(opts, :cache_identity, fn -> RetainedCache.identity(current_boot) end)

    identity = {identity, Keyword.get(opts, :tickets)}

    RetainedCache.fetch(
      __MODULE__,
      identity,
      fn ->
        case Keyword.get(opts, :prior_loader) do
          nil -> load_newest(current_boot, analyzable?, opts)
          loader when is_function(loader, 0) -> loader.()
        end
      end,
      max_value_bytes: 24 * 1024 * 1024
    )
  end

  defp load_newest(current_boot, analyzable?, opts) do
    {indexed, unreadable?} = summary_index(current_boot, opts)

    case load_indexed(indexed, unreadable?, analyzable?, opts) do
      {{:ok, dataset}, unreadable?, skipped_newer} ->
        retained_runs = %{included: 1, total: length(indexed), skipped_large: skipped_newer, skipped_newer: skipped_newer}
        {[Map.put(dataset, :retained_runs, retained_runs)], unreadable?}

      {:none, unreadable?, skipped_large, _scanned_bytes} ->
        {[], if(skipped_large > 0, do: :scan_limited, else: unreadable?)}
    end
  end

  defp summary_index(current_boot, opts) do
    Summaries.summary_boot_ids()
    |> Enum.reject(&(&1 == current_boot))
    |> Enum.reduce({[], false}, &index_summary(&1, &2, opts))
  end

  defp index_summary(boot_id, {indexed, unreadable?}, opts) do
    index_loader = Keyword.get(opts, :summary_index_loader, &SummaryIndex.time_range_end/1)

    case index_loader.(boot_id) do
      {:ok, observed_at, _bytes_read, file_bytes} ->
        {[{observed_at, boot_id, file_bytes} | indexed], unreadable?}

      {:error, _reason, _bytes_read, _file_bytes} ->
        {indexed, true}
    end
  end

  defp load_indexed(indexed, unreadable?, analyzable?, opts) do
    dataset_loader = Keyword.get(opts, :summary_dataset_loader, &Summaries.load_dataset/1)

    indexed
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce_while({:none, unreadable?, 0, 0}, &choose_newest(&1, &2, analyzable?, dataset_loader))
  end

  defp choose_newest({_observed_at, _boot_id, file_bytes}, {:none, unreadable?, skipped, scanned}, _analyzable?, _dataset_loader)
       when file_bytes + scanned > @max_scan_bytes do
    {:cont, {:none, unreadable?, skipped + 1, scanned}}
  end

  defp choose_newest({_observed_at, boot_id, file_bytes}, {:none, unreadable?, skipped, scanned}, analyzable?, dataset_loader) do
    case dataset_loader.(boot_id) do
      {:ok, dataset} ->
        if analyzable?.(dataset), do: {:halt, {{:ok, dataset}, unreadable?, skipped}}, else: {:cont, {:none, unreadable?, skipped, scanned + file_bytes}}

      {:error, _reason} ->
        {:cont, {:none, true, skipped, scanned + file_bytes}}
    end
  end

  defp choose_newest(_entry, {{:ok, dataset}, unreadable?, skipped}, _analyzable?, _dataset_loader),
    do: {:halt, {{:ok, dataset}, unreadable?, skipped}}

  defp observed_at(dataset), do: get_in(dataset, [:provenance, :time_range, :end]) || ""
end
