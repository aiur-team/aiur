defmodule AiurWeb.OperatorControlCenter.Analytics.LatestRun do
  @moduledoc """
  Selects the newest analyzable dataset for the Analytics latest-run view.

  A daemon restart moves live telemetry to a fresh log root. Until that stream
  records agent or ticket activity, the newest materialized prior run remains
  the truthful latest analyzable dataset.
  """

  alias Aiur.RunTelemetry.{Dataset, Summaries}

  @spec load(Path.t(), String.t() | nil, (map() -> boolean())) ::
          {:ok, map()} | {:error, term()}
  def load(file, current_boot, analyzable?) when is_function(analyzable?, 1) do
    live = Dataset.build(file, session: :current, boot_id: current_boot)

    case live do
      {:ok, dataset} ->
        if analyzable?.(dataset), do: live, else: latest_prior(current_boot, live, analyzable?)

      {:error, _reason} ->
        latest_prior(current_boot, live, analyzable?)
    end
  end

  defp latest_prior(current_boot, fallback, analyzable?) do
    current_boot
    |> Summaries.load_prior_datasets()
    |> Enum.filter(analyzable?)
    |> Enum.max_by(&observed_at/1, &>=/2, fn -> nil end)
    |> case do
      nil -> fallback
      dataset -> {:ok, dataset}
    end
  end

  defp observed_at(dataset), do: get_in(dataset, [:provenance, :time_range, :end]) || ""
end
