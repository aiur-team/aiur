defmodule Aiur.GitHub.LandingWithdrawal do
  @moduledoc """
  Takes a pull request out of the merge queue and turns its auto-merge off.

  A `CHANGES_REQUESTED` review does not touch the queue on GitHub's side, so a
  rejected PR keeps its slot and its group keeps failing (#4676). An Executor
  approval later lands the PR through the normal merge path.
  """

  alias Aiur.GitHub.Transport

  @type action :: :dequeued | :auto_merge_disabled

  @spec approved_auto_merge_head(integer(), keyword()) ::
          {:ok, %{head_sha: String.t(), approved_head_sha: String.t()}} | :not_applicable | {:error, term()}
  def approved_auto_merge_head(pr_number, opts \\ []) when is_integer(pr_number) do
    query =
      "query AiurStaleApprovedHead($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { state headRefOid reviewDecision autoMergeRequest { enabledAt } reviews(states: APPROVED, last: 1) { nodes { commit { oid } } } } } }"

    with {:ok, token} <- Transport.require_token(opts),
         {:ok, {owner, name}} <- Transport.parse_repo(),
         {:ok, body} <-
           Transport.github_graphql(Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), token, query, %{"owner" => owner, "name" => name, "number" => pr_number},
             caller: "stale_approved_head"
           ) do
      approved_auto_merge_heads(get_in(body, ["data", "repository", "pullRequest"]))
    else
      {:error, _reason} = error -> error
    end
  end

  defp approved_auto_merge_heads(nil), do: :not_applicable

  defp approved_auto_merge_heads(%{"state" => state}) when state != "OPEN", do: :not_applicable
  defp approved_auto_merge_heads(%{"state" => "OPEN", "autoMergeRequest" => nil}), do: :not_applicable

  defp approved_auto_merge_heads(%{"state" => "OPEN", "reviewDecision" => decision}) when decision != "APPROVED",
    do: :not_applicable

  defp approved_auto_merge_heads(%{
         "state" => "OPEN",
         "headRefOid" => head,
         "reviewDecision" => "APPROVED",
         "autoMergeRequest" => %{},
         "reviews" => %{"nodes" => [%{"commit" => %{"oid" => approved}}]}
       })
       when is_binary(head) and is_binary(approved) do
    if head == approved, do: :not_applicable, else: {:ok, %{head_sha: head, approved_head_sha: approved}}
  end

  defp approved_auto_merge_heads(_incomplete), do: {:error, :approval_or_auto_merge_unconfirmed}

  @spec withdraw(integer(), keyword()) :: {:ok, [action()]} | {:error, term(), [action()]}
  def withdraw(pr_number, opts \\ []) when is_integer(pr_number) do
    withdraw(pr_number, opts, :queue_and_auto_merge)
  end

  @spec disable_auto_merge(integer(), keyword()) :: {:ok, [action()]} | {:error, term(), [action()]}
  def disable_auto_merge(pr_number, opts \\ []) when is_integer(pr_number) do
    withdraw(pr_number, opts, :auto_merge_only)
  end

  defp withdraw(pr_number, opts, mode) do
    with {:ok, token} <- Transport.require_token(opts),
         {:ok, {owner, name}} <- Transport.parse_repo() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      caller = Keyword.get(opts, :caller, "landing_withdrawal")
      graphql = fn query, variables -> Transport.github_graphql(request_fun, token, query, variables, caller: caller) end
      withdraw_read(graphql, fn -> read(graphql, owner, name, pr_number) end, mode)
    else
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp withdraw_read(graphql, read, mode) do
    with {:ok, pr} <- read.(),
         {:ok, dequeued} <- if(mode == :auto_merge_only, do: {:ok, []}, else: dequeue(graphql, pr)) do
      # Dequeuing can clear the auto-merge request itself, so re-read before disabling it.
      with {:ok, pr} <- reread(dequeued, pr, read),
           {:ok, disabled} <- disable_auto_merge_request(graphql, pr) do
        {:ok, dequeued ++ disabled}
      else
        {:error, reason} -> {:error, reason, dequeued}
      end
    else
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp reread([], pr, _read), do: {:ok, pr}
  defp reread(_dequeued, _pr, read), do: read.()

  defp read(graphql, owner, name, number) do
    query = """
    query AiurLandingWithdrawal($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) { id mergeQueueEntry { id } autoMergeRequest { enabledAt } } }
    }
    """

    case graphql.(query, %{"owner" => owner, "name" => name, "number" => number}) do
      {:ok, %{"data" => %{"repository" => %{"pullRequest" => %{"id" => id} = pr}}}} when is_binary(id) -> {:ok, pr}
      {:ok, _body} -> {:error, :invalid_pull_request}
      {:error, _reason} = error -> error
    end
  end

  defp dequeue(graphql, %{"id" => id, "mergeQueueEntry" => %{}}) do
    query = "mutation AiurDequeuePullRequest($id: ID!) { dequeuePullRequest(input: {id: $id}) { mergeQueueEntry { id } } }"

    case graphql.(query, %{"id" => id}) do
      {:ok, %{"data" => %{"dequeuePullRequest" => %{}}}} -> {:ok, [:dequeued]}
      {:ok, _body} -> {:error, :dequeue_unconfirmed}
      {:error, _reason} = error -> error
    end
  end

  defp dequeue(_graphql, _pr), do: {:ok, []}

  defp disable_auto_merge_request(graphql, %{"id" => id, "autoMergeRequest" => %{}}) do
    query = "mutation AiurDisableAutoMerge($id: ID!) { disablePullRequestAutoMerge(input: {pullRequestId: $id}) { pullRequest { id } } }"

    case graphql.(query, %{"id" => id}) do
      {:ok, %{"data" => %{"disablePullRequestAutoMerge" => %{}}}} -> {:ok, [:auto_merge_disabled]}
      {:ok, _body} -> {:error, :disable_auto_merge_unconfirmed}
      {:error, _reason} = error -> error
    end
  end

  defp disable_auto_merge_request(_graphql, _pr), do: {:ok, []}
end
