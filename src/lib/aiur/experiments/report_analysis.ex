defmodule Aiur.Experiments.ReportAnalysis do
  @moduledoc false
  alias Aiur.Experiments.{AnalysisInput, AnalysisResult, Catalog, Evidence, Paths, Persistence, Reader, ReportEngine, ReportInput, ReportRecords, StatsRunner, WindowEvents}

  @spec prepare(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(id, catalog_context) do
    with {:ok, input} <- ReportInput.prepare(id),
         {:ok, records} <- ReportRecords.read(id),
         {:ok, registration} <- registration(records),
         {:ok, events} <- WindowEvents.snapshot(input.spec),
         catalog = Catalog.load(catalog_context),
         {:ok, body} <- recompute(input, registration, catalog, catalog_context) do
      context = ReportEngine.context(body, registration, events, catalog)
      {:ok, %{input: input, records: records, context: context, body: body}}
    end
  end

  defp registration(%{"preregistration" => nil}), do: {:error, [%{path: "preregistration", message: "register before requesting statistics"}]}
  defp registration(%{"preregistration" => record}), do: {:ok, record}

  defp recompute(input, registration, catalog, catalog_context) do
    spec = ReportEngine.spec(input.input, registration, catalog)
    # One immutable input directory per hash; the runner alone replaces its computed result.
    dir = stats_directory(input, spec)

    with :ok <- Aiur.Journal.ensure_directory(dir),
         :ok <- Persistence.write_json(Path.join(dir, "snapshot.json"), input.input),
         :ok <- Persistence.write_json(Path.join(dir, "spec.json"), spec),
         :ok <- Persistence.write_json(Path.join(dir, "annotations.json"), %{}),
         :ok <- StatsRunner.recompute(dir, reduce_dir: catalog_context[:reduce_dir]),
         {:ok, %{"body" => body}} <- Reader.json(Path.join(dir, "result.json")) do
      {:ok, body}
    end
  end

  @doc "Read the cached result for the current frozen inputs; never run the engine."
  @spec cached(String.t()) :: {:ok, map()} | {:error, term()}
  def cached(id) do
    with {:ok, input} <- ReportInput.prepare(id),
         {:ok, records} <- ReportRecords.read(id),
         {:ok, registration} <- registration(records),
         catalog = Catalog.load(),
         true <- Enum.all?(input.spec["metrics"], &Map.has_key?(catalog.metrics, &1["ref"])),
         spec = ReportEngine.spec(input.input, registration, catalog),
         {:ok, %{"body" => body}} <- Reader.json(Path.join(stats_directory(input, spec), "result.json")),
         :ok <- AnalysisResult.validate(body, input.spec) do
      {:ok, %{analysis: body, chart_metric_specs: spec["metrics"]}}
    else
      false -> {:error, :metric_unavailable}
      {:ok, _invalid} -> {:error, :unreadable}
      error -> error
    end
  end

  defp stats_directory(input, spec), do: Paths.file(input.id, "report/stats/" <> Evidence.hash(%{input: input.input, spec: spec}))

  @spec unchanged(map()) :: :ok | {:error, term()}
  def unchanged(prepared) do
    with :ok <- ReportInput.unchanged(prepared.input),
         {:ok, records} <- ReportRecords.read(prepared.input.id),
         {:ok, events} <- WindowEvents.snapshot(prepared.input.spec),
         true <- records == prepared.records and events["snapshot_hash"] == prepared.context.events["snapshot_hash"] do
      :ok
    else
      false -> {:error, :stale_preparation}
      error -> error
    end
  end

  @spec commit(map()) :: {:ok, map()} | {:error, term()}
  def commit(prepared) do
    with :ok <- unchanged(prepared),
         {:ok, _input} <- AnalysisInput.commit(prepared.input),
         :ok <- ReportRecords.record_results_read(prepared.input.id, DateTime.utc_now()) do
      {:ok, %{"snapshot_hash" => prepared.context.stats_snapshot_hash, "body" => prepared.body, "report_results" => Map.values(prepared.context.engine_results)}}
    end
  end
end
