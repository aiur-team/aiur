defmodule Aiur.PrMerge.Queue do
  @moduledoc false

  @spec enqueue(function(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def enqueue(api, %{node_id: id, head: head}) when is_binary(id) and id != "" and is_binary(head) do
    query = """
    mutation($input: EnqueuePullRequestInput!) {
      enqueuePullRequest(input: $input) {
        mergeQueueEntry { id pullRequest { id headRefOid } }
      }
    }
    """

    body = %{query: query, variables: %{input: %{pullRequestId: id, expectedHeadOid: head}}}

    case api.("post", "graphql", body) do
      {:ok, %{"data" => %{"enqueuePullRequest" => %{"mergeQueueEntry" => %{"id" => entry, "pullRequest" => %{"id" => ^id, "headRefOid" => ^head}}}}} = response}
      when is_binary(entry) and entry != "" ->
        if Map.has_key?(response, "errors"), do: {:error, "GitHub did not confirm enqueue"}, else: {:ok, entry}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, "GitHub did not confirm enqueue at the reviewed head"}
    end
  end

  def enqueue(_api, _pr), do: {:error, "missing pull request node identity; cannot enqueue"}
end
