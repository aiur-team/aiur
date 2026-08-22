defmodule AiurWeb.OperatorControlCenter.Analytics.LatestRun do
  @moduledoc """
  Selects the newest analyzable dataset for the Analytics latest-run view.

  A daemon restart moves live telemetry to a fresh log root. Until that stream
  records agent or ticket activity, the newest materialized prior run remains
  the truthful latest analyzable dataset.

  Decoded prior summaries are cached in an ETS table so the Build Order pane's
  30-second idle retry does not re-decode them. The cache key folds in each
  summary's file metadata, so a new or regenerated summary invalidates the
  entry without retaining one key per boot forever. ETS is deliberate:
  `:persistent_term` would `put` on every materialization and force a global
  literal-area GC across every process in the VM — including the daemon. The
  table is owned by the caller (a LiveView or the CLI) and dies with it, which
  is fine for a best-effort cache: losing it costs one re-decode.

  When retained summaries exist but none of them can be decoded — a truncated
  or corrupt `run-summary.json` — `load/4` returns `{:error, :retained_unreadable}`
  instead of the empty live fallback, so the page never mistakes a persistence
  failure for an idle fleet.
  """

  alias Aiur.RunTelemetry.{Dataset, Summaries}

  @cache_table __MODULE__
  @cache_options [:named_table, :public, :set, read_concurrency: true]

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
    {datasets, unreadable?} = prior_datasets(opts, current_boot)

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
  defp prior_datasets(opts, current_boot) do
    identity = Keyword.get_lazy(opts, :cache_identity, fn -> cache_identity(current_boot) end)

    case cache_get(identity) do
      {:ok, cached} ->
        cached

      :miss ->
        value =
          case Keyword.get(opts, :prior_loader) do
            nil -> Summaries.load_prior_datasets_with_state(current_boot)
            loader when is_function(loader, 0) -> loader.()
          end

        cache_put(identity, value)
        value
    end
  end

  defp cache_identity(current_boot) do
    summaries =
      Summaries.summary_boot_ids()
      |> Enum.reject(&(&1 == current_boot))
      |> Enum.map(fn boot_id ->
        path = Summaries.run_summary_path(boot_id)

        case File.stat(path, time: :posix) do
          {:ok, stat} -> {boot_id, stat.size, stat.mtime}
          {:error, reason} -> {boot_id, reason}
        end
      end)

    {Summaries.state_node(), current_boot, summaries}
  end

  defp cache_get(key) do
    if cache_table?() do
      case :ets.lookup(@cache_table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> :miss
      end
    else
      :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(key, value) do
    ensure_table()
    :ets.insert(@cache_table, {key, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cache_table? do
    :ets.whereis(@cache_table) != :undefined
  end

  # A public named table owned by the calling process. Concurrent callers that
  # race to create it lose the race cleanly and reuse the winner's table; a
  # caller whose table has died simply falls back to a re-decode.
  defp ensure_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, @cache_options)
        rescue
          ArgumentError -> :ok
        end

      _table ->
        :ok
    end
  end

  defp observed_at(dataset), do: get_in(dataset, [:provenance, :time_range, :end]) || ""
end
