defmodule Aiur.Experiments.ReportSubmission do
  @moduledoc false
  alias Aiur.Experiments.{AnalysisRequests, ContractSchema, ReportAnalysis, ReportContract, ReportRecords}

  @spec prepare(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(id, report, context) do
    with :ok <- ContractSchema.validate(report, "report"),
         {:ok, prepared} <- ReportAnalysis.prepare(id, context),
         {:ok, report, warnings} <- ReportContract.validate(report, prepared.context) do
      {:ok, Map.merge(prepared, %{report: report, warnings: warnings})}
    end
  end

  @spec commit(map()) :: {:ok, map()} | {:error, term()}
  def commit(prepared) do
    with :ok <- ReportAnalysis.unchanged(prepared) do
      reports = prepared.records["reports"]
      version = length(reports) + 1
      report = prepared.report |> put_in(["header", "report_version"], version) |> put_in(["header", "generated_at"], DateTime.utc_now() |> DateTime.to_iso8601())
      records = prepared.records |> Map.put("reports", reports ++ [report]) |> Map.update!("first_results_read_at", &(&1 || DateTime.to_iso8601(DateTime.utc_now())))

      with :ok <- ReportRecords.write(prepared.input.id, records),
           :ok <- AnalysisRequests.submitted(prepared.input.id, "report", report),
           do: {:ok, %{"report" => report, "warnings" => prepared.warnings}}
    end
  end
end
