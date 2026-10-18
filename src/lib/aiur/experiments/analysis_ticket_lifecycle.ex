defmodule Aiur.Experiments.AnalysisTicketLifecycle do
  @moduledoc false

  @spec failure(map(), Aiur.Tracker.open_issue_labels_result(), integer()) :: String.t() | nil
  def failure(%{"state" => "open", "ticket" => %{"number" => number}} = request, {:ok, tickets, observed_at}, now) do
    with {:ok, revised_at, _offset} <- DateTime.from_iso8601(request["at"] || ""),
         true <- observed_at > DateTime.to_unix(revised_at, :millisecond),
         true <- (now - observed_at) in 0..120_000 do
      case Map.fetch(tickets, to_string(number)) do
        :error -> "analysis_ticket_closed_without_submission"
        {:ok, %{labels: labels}} -> terminal_label(labels)
        _unknown -> nil
      end
    else
      _unavailable -> nil
    end
  end

  def failure(_request, _snapshot, _now), do: nil

  defp terminal_label(labels) do
    cond do
      "agent:error" in labels -> "analysis_ticket_error_without_submission"
      "agent:done" in labels -> "analysis_ticket_done_without_submission"
      true -> nil
    end
  end
end
