defmodule AiurWeb.OperatorControlCenter.Analytics.LatestRun do
  @moduledoc """
  Selects the newest analyzable dataset for the Analytics latest-run view.

  A daemon restart moves live telemetry to a fresh log root. Until that stream
  records agent or ticket activity, the newest materialized prior run remains
  the truthful latest analyzable dataset.

  Only the newest analyzable prior summary is retained in a bounded cache.
  A persistent cache owner serializes cold loads and survives request exits.
  File metadata invalidates regenerated summaries without retaining every boot.

  When retained summaries exist but none of them can be decoded — a truncated
  or corrupt `run-summary.json` — `load/4` returns `{:error, :retained_unreadable}`
  instead of the empty live fallback, so the page never mistakes a persistence
  failure for an idle fleet.
  """

  alias Aiur.RunTelemetry.{Dataset, Summaries}

  alias Aiur.RunTelemetry.RetainedCache

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
          nil -> load_newest(current_boot, analyzable?)
          loader when is_function(loader, 0) -> loader.()
        end
      end,
      max_value_bytes: 24 * 1024 * 1024
    )
  end

  defp load_newest(current_boot, analyzable?) do
    Summaries.summary_boot_ids()
    |> Enum.reject(&(&1 == current_boot))
    |> Enum.reduce({[], false}, &choose_newest(&1, &2, analyzable?))
  end

  defp choose_newest(boot_id, {newest, unreadable?}, analyzable?) do
    case Summaries.load_dataset(boot_id) do
      {:ok, dataset} ->
        candidates = if analyzable?.(dataset), do: [dataset | newest], else: newest
        {Enum.take(Enum.sort_by(candidates, &observed_at/1, :desc), 1), unreadable?}

      {:error, _reason} ->
        {newest, true}
    end
  end

  defp observed_at(dataset), do: get_in(dataset, [:provenance, :time_range, :end]) || ""
end
