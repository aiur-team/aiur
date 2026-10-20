defmodule Aiur.Experiments.AnalysisRecovery do
  @moduledoc false
  alias Aiur.Experiments.{AnalysisRequests, Reader, ReportRecords}

  @spec reconcile(String.t()) :: :ok | {:error, term()}
  def reconcile(id) do
    with {:ok, _spec, false} <- Reader.spec(id), {:ok, rows} <- AnalysisRequests.history(id), {:ok, records} <- ReportRecords.read(id) do
      rows |> AnalysisRequests.latest() |> Enum.filter(&(&1["state"] == "open")) |> Enum.reduce_while(:ok, &recover(&1, records, &2))
    else
      {:ok, _spec, true} -> {:error, :store_read_only}
      error -> error
    end
  end

  defp recover(request, records, :ok) do
    mode = request["mode"]
    candidates = if mode == "spec", do: List.wrap(records["preregistration"]), else: Enum.reverse(records["reports"])
    record = Enum.find(candidates, &newer?(&1, mode, request["requested_at"] || request["at"]))
    result = if record, do: AnalysisRequests.submitted(request["experiment_id"], mode, record), else: :ok

    case result do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp newer?(record, "spec", at) do
    latest = List.last(record["amendments"] || [])
    not_before?(if(latest, do: latest["at"], else: record["registered_at"]), at)
  end

  defp newer?(record, "report", at), do: not_before?(get_in(record, ["header", "generated_at"]), at)

  defp not_before?(left, right) do
    with {:ok, left, _offset} <- DateTime.from_iso8601(left || ""), {:ok, right, _offset} <- DateTime.from_iso8601(right || "") do
      DateTime.compare(left, right) != :lt
    else
      _invalid -> false
    end
  end
end
