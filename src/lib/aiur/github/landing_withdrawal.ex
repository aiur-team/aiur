defmodule Aiur.GitHub.LandingWithdrawal do
  @moduledoc """
  Takes a pull request out of the merge queue and turns its auto-merge off.

  A `CHANGES_REQUESTED` review does not touch the queue on GitHub's side, so a
  rejected PR keeps its slot and its group keeps failing (#4676). An Executor
  approval later lands the PR through the normal merge path.
  """

  alias Aiur.GitHub.Transport

  @type action :: :dequeued | :auto_merge_disabled

  @spec withdraw(integer(), keyword()) :: {:ok, [action()]} | {:error, term(), [action()]}
  def withdraw(pr_number, opts \\ []) when is_integer(pr_number) do
    with {:ok, token} <- Transport.require_token(opts),
         {:ok, {owner, name}} <- Transport.parse_repo() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      graphql = fn query, variables -> Transport.github_graphql(request_fun, token, query, variables, caller: "landing_withdrawal") end
      withdraw_read(graphql, fn -> read(graphql, owner, name, pr_number) end)
    else
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp withdraw_read(graphql, read) do
    with {:ok, pr} <- read.(),
         {:ok, dequeued} <- dequeue(graphql, pr) do
      # Dequeuing can clear the auto-merge request itself, so re-read before disabling it.
      with {:ok, pr} <- reread(dequeued, pr, read),
           {:ok, disabled} <- disable_auto_merge(graphql, pr) do
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

  defp disable_auto_merge(graphql, %{"id" => id, "autoMergeRequest" => %{}}) do
    query = "mutation AiurDisableAutoMerge($id: ID!) { disablePullRequestAutoMerge(input: {pullRequestId: $id}) { pullRequest { id } } }"

    case graphql.(query, %{"id" => id}) do
      {:ok, %{"data" => %{"disablePullRequestAutoMerge" => %{}}}} -> {:ok, [:auto_merge_disabled]}
      {:ok, _body} -> {:error, :disable_auto_merge_unconfirmed}
      {:error, _reason} = error -> error
    end
  end

  defp disable_auto_merge(_graphql, _pr), do: {:ok, []}
end
