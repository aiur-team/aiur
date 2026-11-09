defmodule Aiur.GitHub.ClosedTicketPullRequest do
  @moduledoc false
  alias Aiur.GitHub.Access

  @query """
  query AiurCorrectiveMergedPullRequest($owner: String!, $repository: String!, $number: Int!) {
    repository(owner: $owner, name: $repository) {
      issue(number: $number) {
        state
        closedByPullRequestsReferences(first: 100, includeClosedPrs: true) {
          nodes {
            number
            repository { nameWithOwner }
            mergedAt
            mergeCommit { oid }
            headRefName
            headRefOid
            baseRefName
          }
          pageInfo { hasNextPage }
        }
      }
    }
  }
  """

  @spec read(String.t(), keyword()) :: Aiur.Tracker.ticket_pull_request_result()
  def read(identifier, opts) do
    with {number, ""} when number > 0 <- Integer.parse(identifier),
         {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token(opts),
         request <- Keyword.get(opts, :request_fun, &Access.default_request_fun/1),
         {:ok, response, _transport} <-
           Access.github_graphql_response(request, token, @query, %{"owner" => owner, "repository" => repo, "number" => number}, max_response_bytes: 131_072, caller: "command_override_merged_pr") do
      parse(get_in(response, ["data", "repository", "issue"]), "#{owner}/#{repo}")
    else
      {:error, reason, _transport} -> {:error, reason}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_ticket_identifier}
    end
  end

  defp parse(%{"state" => "OPEN"}, _repo), do: {:ok, nil}

  defp parse(%{"state" => "CLOSED", "closedByPullRequestsReferences" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}, repo) when is_list(nodes) do
    merged = Enum.filter(nodes, &(valid_merged?(&1) and same_repo?(&1, repo))) |> Enum.max_by(& &1["mergedAt"], fn -> nil end)
    {:ok, if(merged, do: normalize(merged), else: %{state: :closed, merged?: false})}
  end

  defp parse(%{"closedByPullRequestsReferences" => %{"pageInfo" => %{"hasNextPage" => true}}}, _repo), do: {:error, :incomplete_merged_pr_lookup}
  defp parse(_invalid, _repo), do: {:error, :invalid_merged_pr_lookup}

  defp same_repo?(%{"repository" => %{"nameWithOwner" => name}}, repo) when is_binary(name), do: String.downcase(name) == String.downcase(repo)
  defp same_repo?(_node, _repo), do: false

  defp valid_merged?(%{"number" => number, "mergedAt" => at, "mergeCommit" => %{"oid" => sha}}),
    do: is_integer(number) and number > 0 and is_binary(at) and at != "" and is_binary(sha) and sha != ""

  defp valid_merged?(_node), do: false
  defp normalize(nil), do: nil

  defp normalize(node) do
    %{state: :closed, merged?: true, number: node["number"], merge_commit_sha: node["mergeCommit"]["oid"], head_ref: node["headRefName"], head_sha: node["headRefOid"], base_ref: node["baseRefName"]}
  end
end
