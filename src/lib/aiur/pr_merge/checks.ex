defmodule Aiur.PrMerge.Checks do
  @moduledoc false
  alias Aiur.PrMerge.Reviews

  @spec read(function(), String.t(), pos_integer(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def read(api, repo, number, head) do
    [owner, name] = String.split(repo, "/")
    query = query()
    variables = %{owner: owner, name: name, number: number}

    with {:ok, %{"data" => %{"repository" => %{"pullRequest" => pr}}} = response} <- api.("post", "graphql", %{query: query, variables: variables}),
         true <- not Map.has_key?(response, "errors"),
         %{"nodes" => [%{"commit" => %{"oid" => ^head, "statusCheckRollup" => rollup}}]} <- pr["commits"],
         {:ok, checks} <- contexts(rollup),
         %{"nodes" => tickets, "pageInfo" => %{"hasNextPage" => false}} <- pr["closingIssuesReferences"],
         {:ok, reviews} <- Reviews.read(api, repo, number, head) do
      {:ok, Map.merge(reviews, %{checks: checks, tickets: tickets})}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "incomplete or head-mismatched GitHub check observation"}
    end
  end

  @spec classify([map()]) :: map()
  def classify(checks) do
    Enum.reduce(checks, %{passed: [], failed: [], pending: []}, fn check, acc ->
      name = check["name"] || check["context"]
      if state(check) != :failed and String.contains?(name, "${{"), do: acc, else: Map.update!(acc, state(check), &(&1 ++ classified_names(check, name)))
    end)
  end

  defp classified_names(check, name) do
    if state(check) == :passed, do: names(check, name), else: [name]
  end

  defp names(check, name) do
    case get_in(check, ["checkSuite", "app", "databaseId"]) do
      id when is_integer(id) -> [name, "#{name} (app #{id})"]
      _ -> [name]
    end
  end

  defp contexts(nil), do: {:ok, []}

  defp contexts(%{"contexts" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}) when is_list(nodes) do
    if Enum.all?(nodes, &valid?/1), do: {:ok, nodes}, else: {:error, "invalid check state"}
  end

  defp contexts(_rollup), do: {:error, "incomplete check collection; wait for CI"}

  defp valid?(%{"__typename" => "CheckRun", "name" => name, "status" => status} = check),
    do: is_binary(name) and status in ["QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED", "COMPLETED"] and (status != "COMPLETED" or is_binary(check["conclusion"]))

  defp valid?(%{"__typename" => "StatusContext", "context" => name, "state" => state}), do: is_binary(name) and state in ["SUCCESS", "PENDING", "ERROR", "FAILURE", "EXPECTED"]
  defp valid?(_check), do: false
  defp state(%{"__typename" => "StatusContext", "state" => "SUCCESS"}), do: :passed
  defp state(%{"__typename" => "StatusContext", "state" => state}) when state in ["PENDING", "EXPECTED"], do: :pending
  defp state(%{"__typename" => "CheckRun", "status" => status}) when status != "COMPLETED", do: :pending
  defp state(%{"__typename" => "CheckRun", "conclusion" => conclusion}) when conclusion in ["SUCCESS", "NEUTRAL", "SKIPPED"], do: :passed
  defp state(_check), do: :failed

  defp query do
    """
    query($owner:String!, $name:String!, $number:Int!) {
      repository(owner:$owner, name:$name) { pullRequest(number:$number) {
        closingIssuesReferences(first:100) { nodes { number repository { nameWithOwner } } pageInfo { hasNextPage } } commits(last:1) { nodes { commit { oid statusCheckRollup {
          contexts(first:100) { nodes {
            __typename ... on CheckRun { name status conclusion checkSuite { app { databaseId } } }
            ... on StatusContext { context state }
          } pageInfo { hasNextPage } }
        } } } }
      } }
    }
    """
  end
end
