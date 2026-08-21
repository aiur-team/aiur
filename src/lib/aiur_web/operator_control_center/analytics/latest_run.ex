defmodule AiurWeb.OperatorControlCenter.Analytics.LatestRun do
  @moduledoc """
  Selects the newest analyzable dataset for the Analytics latest-run view.

  A daemon restart moves live telemetry to a fresh log root. Until that stream
  records agent or ticket activity, the newest materialized prior run remains
  the truthful latest analyzable dataset.
  """

  alias Aiur.RunTelemetry.{Dataset, Summaries}

  @prior_cache_key {__MODULE__, :prior_datasets}

  @spec load(Path.t(), String.t() | nil, (map() -> boolean())) ::
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

  defp latest_prior(current_boot, fallback, analyzable?, opts) do
    opts
    |> prior_datasets(current_boot)
    |> Enum.filter(analyzable?)
    |> Enum.max_by(&observed_at/1, &>=/2, fn -> nil end)
    |> case do
      nil -> fallback
      dataset -> {:ok, dataset}
    end
  end

  # The Build Order pane can retry this fallback every 30 seconds while a fresh
  # boot is idle. Cache decoded summaries, but include their file metadata so a
  # new or regenerated summary invalidates the entry without retaining one key
  # per boot forever.
  defp prior_datasets(opts, current_boot) do
    identity = Keyword.get_lazy(opts, :cache_identity, fn -> cache_identity(current_boot) end)

    case :persistent_term.get(@prior_cache_key, nil) do
      {^identity, datasets} ->
        datasets

      _other ->
        loader = Keyword.get(opts, :prior_loader, fn -> Summaries.load_prior_datasets(current_boot) end)
        datasets = loader.()
        :persistent_term.put(@prior_cache_key, {identity, datasets})
        datasets
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

  defp observed_at(dataset), do: get_in(dataset, [:provenance, :time_range, :end]) || ""
end
