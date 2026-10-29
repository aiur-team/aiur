defmodule Aiur.Experiments.ChartEvidence do
  @moduledoc false
  alias Aiur.Experiments.{ReportAnalysis, WindowEvents}

  @spec attach(String.t(), map()) :: map()
  def attach(id, detail) do
    detail =
      case ReportAnalysis.cached(id) do
        {:ok, cached} -> Map.merge(detail, cached)
        {:error, _unavailable} -> detail
      end

    case WindowEvents.snapshot(detail.spec) do
      {:ok, snapshot} -> Map.put(detail, :annotations, detail.annotations ++ Enum.map(snapshot["events"], &annotation/1))
      {:error, _unavailable} -> detail
    end
  end

  defp annotation(event), do: %{"at" => event["at"] || event["from"], "label" => event["summary"] || event["title"] || event["ref"] || event["kind"]}
end
