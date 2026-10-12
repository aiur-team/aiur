defmodule Aiur.GitHub.TicketPullRequest do
  @moduledoc "Delivered PR state for build queue prerequisites; never fetches GitHub."
  alias Aiur.GitHub.{DeliveredPullRequest, ResourceStore, Transport}

  @spec read(String.t()) :: Aiur.Tracker.ticket_pull_request_result()
  def read(issue_id) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, %{source: :webhook, fetched_at_ms: fetched, data: body, version: version}} <- ResourceStore.fetch(ResourceStore.key(:branch_pull_request, owner, repo, issue_id)),
         true <- is_integer(fetched) and System.system_time(:millisecond) - fetched < DeliveredPullRequest.max_age_ms() do
      {:ok, parse(body, version)}
    else
      _ -> {:ok, nil}
    end
  end

  defp parse(%{"state" => state, "number" => number, "merged_at" => merged_at} = body, version)
       when state in ["open", "closed"] and is_integer(number) and number > 0 and (is_nil(merged_at) or is_binary(merged_at)) do
    case Map.get(body, "merged") do
      merged when merged in [nil, false, true] ->
        %{
          state: if(state == "open", do: :open, else: :closed),
          merged?: merged == true or not is_nil(merged_at),
          number: number,
          version: version,
          head_ref: get_in(body, ["head", "ref"]),
          head_sha: get_in(body, ["head", "sha"]),
          base_ref: get_in(body, ["base", "ref"]),
          merge_commit_sha: Map.get(body, "merge_commit_sha")
        }

      _ ->
        nil
    end
  end

  defp parse(_body, _version), do: nil
end
