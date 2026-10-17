defmodule Aiur.Experiments.ReportAnalysis do
  @moduledoc false
  alias Aiur.Experiments.{AnalysisInput, Catalog, Evidence, Paths, Persistence, Reader, ReportEngine, ReportInput, ReportRecords, StatsRunner, WindowEvents}

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
    dir = Paths.file(input.id, "report/stats/" <> Evidence.hash(%{input: input.input, spec: spec}))

    with :ok <- Aiur.Journal.ensure_directory(dir),
         :ok <- Persistence.write_json(Path.join(dir, "snapshot.json"), input.input),
         :ok <- Persistence.write_json(Path.join(dir, "spec.json"), spec),
         :ok <- Persistence.write_json(Path.join(dir, "annotations.json"), %{}),
         :ok <- StatsRunner.recompute(dir, reduce_dir: catalog_context[:reduce_dir]),
         {:ok, %{"body" => body}} <- Reader.json(Path.join(dir, "result.json")) do
      {:ok, body}
    end
  end

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
