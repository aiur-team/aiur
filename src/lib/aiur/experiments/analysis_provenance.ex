defmodule Aiur.Experiments.AnalysisProvenance do
  @moduledoc false
  alias Aiur.Experiments.{AnalysisRequests, Paths}
  alias Aiur.Issue

  @marker ~r/<!-- aiur-experiment-analysis request=(req-[a-f0-9]{32}) nonce=([a-f0-9]{32}) -->/

  @spec check(Issue.t()) :: boolean()
  def check(%Issue{labels: labels} = issue) do
    "experiment-analysis" in labels and match?([_one], markers(issue.description)) and matching_request?(issue)
  end

  defp matching_request?(issue) do
    with {:ok, ids} <- Paths.ids() do
      Enum.any?(ids, fn id ->
        case AnalysisRequests.history(id) do
          {:ok, rows} -> Enum.any?(AnalysisRequests.latest(rows), &authorized?(issue, &1))
          {:error, _reason} -> false
        end
      end)
    else
      {:error, _reason} -> false
    end
  end

  @spec authorized?(Issue.t(), map()) :: boolean()
  def authorized?(%Issue{} = issue, %{"state" => "open", "ticket" => %{"number" => number, "url" => url}, "daemon_login" => daemon} = request)
      when is_integer(number) and number > 0 and is_binary(url) and is_binary(daemon) and daemon != "" do
    "experiment-analysis" in issue.labels and to_string(number) == issue.id and url == issue.url and
      String.downcase(issue.creator_login || "") == String.downcase(daemon) and matching_marker?(issue.description, request)
  end

  def authorized?(_issue, _request), do: false

  defp matching_marker?(body, request) do
    case markers(body) do
      [[_, request_id, nonce]] -> request_id == request["request_id"] and secure_equal?(nonce, request["nonce"])
      _invalid -> false
    end
  end

  defp markers(body) when is_binary(body), do: Regex.scan(@marker, body)
  defp markers(_body), do: []

  defp secure_equal?(left, right) when is_binary(right) and byte_size(left) == byte_size(right), do: :crypto.hash_equals(left, right)
  defp secure_equal?(_left, _right), do: false
end
