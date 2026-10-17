defmodule Aiur.LandingWatch.Observer do
  @moduledoc "Governed GraphQL observation for open PR approval, CI and queue state."

  alias Aiur.GitHub.{Client, Transport}
  alias Aiur.LandingWatch.Classifier

  @spec observe(keyword()) :: {:ok, [map()]} | {:error, term()}
  def observe(opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, prs} <- Client.fetch_open_pull_requests(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      observe_chunks(prs, owner, repo, token, request_fun)
    end
  end

  @doc false
  @spec refresh_queue([map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def refresh_queue(observations, opts) when is_list(observations) do
    candidates = Enum.filter(observations, &queue_candidate?/1)

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      observe_chunks(Enum.map(candidates, &Map.get(&1, :rest)), owner, repo, token, request_fun)
    end
  end

  def refresh_queue(_, _), do: {:error, :invalid_queue_observations}

  @doc false
  @spec revalidate_approved_head(pos_integer(), String.t(), keyword()) :: :ok | {:error, term()}
  def revalidate_approved_head(number, expected_head, opts) when is_integer(number) and number > 0 and is_binary(expected_head) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, %{"data" => %{"repository" => %{"pullRequest" => pr}}}} <-
           Transport.github_graphql(
             Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
             token,
             "query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){headRefOid reviewDecision autoMergeRequest{enabledAt} mergeQueueEntry { id } reviews(states:APPROVED,last:1){nodes{commit{oid}}}}}}",
             %{owner: owner, repo: repo, number: number},
             caller: "landing_watch_revalidate"
           ),
         true <-
           Map.get(pr, "headRefOid") == expected_head and Classifier.approved_at_head?(pr) and
             is_nil(Map.get(pr, "mergeQueueEntry")) and is_nil(Map.get(pr, "autoMergeRequest")) do
      :ok
    else
      {:error, _} = error -> error
      false -> {:error, :approval_or_head_changed}
      _ -> {:error, :invalid_approval_revalidation}
    end
  end

  def revalidate_approved_head(_, _, _), do: {:error, :invalid_approval_revalidation}

  defp observe_chunks(prs, owner, repo, token, request_fun) do
    prs
    |> Enum.chunk_every(25)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} -> append_observations(chunk, acc, owner, repo, token, request_fun) end)
  end

  defp append_observations(chunk, acc, owner, repo, token, request_fun) do
    case observe_batch(chunk, owner, repo, token, request_fun) do
      {:ok, observations} -> {:cont, {:ok, acc ++ observations}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp observe_batch([], _owner, _repo, _token, _request_fun), do: {:ok, []}

  defp observe_batch(prs, owner, repo, token, request_fun) do
    if Enum.any?(prs, &(not (is_integer(&1["number"]) and &1["number"] > 0))) do
      {:error, :invalid_pull_request_number}
    else
      observe_valid_batch(prs, owner, repo, token, request_fun)
    end
  end

  defp observe_valid_batch(prs, owner, repo, token, request_fun) do
    aliases = prs |> Enum.with_index() |> Enum.map_join("\n", fn {pr, i} -> "pr_#{i}: pullRequest(number: #{pr["number"]}) { " <> fields() <> " }" end)

    query = "query AiurLandingWatch($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { #{aliases} } }"

    with {:ok, %{"data" => %{"repository" => repository}}} <-
           Transport.github_graphql(request_fun, token, query, %{"owner" => owner, "repo" => repo}, caller: "landing_watch_observation"),
         true <- is_map(repository) do
      observations = prs |> Enum.with_index() |> Enum.map(fn {rest, i} -> normalize(rest, Map.get(repository, "pr_#{i}")) end)
      if Enum.all?(observations, &is_map/1), do: {:ok, observations}, else: {:error, :incomplete_landing_observation}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_landing_observation}
    end
  end

  defp normalize(rest, %{} = pr) do
    %{
      node_id: Map.get(pr, "id"),
      number: Map.get(rest, "number"),
      rest: rest,
      raw: pr,
      head: Map.get(pr, "headRefOid"),
      head_committed_at: get_in(pr, ["commits", "nodes"]) |> List.wrap() |> List.last() |> then(&get_in(&1 || %{}, ["commit", "committedDate"])),
      state: Map.get(pr, "state"),
      base: Map.get(pr, "baseRefName"),
      draft?: Map.get(pr, "isDraft"),
      review_decision: Map.get(pr, "reviewDecision"),
      reviews: get_in(pr, ["reviews", "nodes"]),
      mergeable: Map.get(pr, "mergeable"),
      merge_state_status: Map.get(pr, "mergeStateStatus"),
      merge_queue_entry: Map.get(pr, "mergeQueueEntry"),
      auto_merge_request: Map.get(pr, "autoMergeRequest")
    }
  end

  defp normalize(_rest, _pr), do: nil

  defp queue_candidate?(%{merge_queue_entry: entry}) when is_map(entry), do: true

  defp queue_candidate?(%{raw: raw}), do: Classifier.approved_at_head?(raw)
  defp queue_candidate?(_), do: false

  defp fields do
    "number id state headRefOid baseRefName isDraft reviewDecision mergeable " <>
      "mergeStateStatus autoMergeRequest { enabledAt } mergeQueueEntry { id headCommit { oid } pullRequest { id headRefOid } } " <>
      "reviews(states: APPROVED, last: 1) { nodes { commit { oid } } } " <>
      "commits(last: 1) { nodes { commit { committedDate } } }"
  end
end
