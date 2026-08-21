defmodule Aiur.Events.GithubWebhook.ThreadResolver do
  @moduledoc """
  Resolves the GitHub review-thread node id a `pull_request_review_comment`
  delivery belongs to.

  The poller's GraphQL batch reads each unaddressed thread's node id directly
  (`Aiur.GitHub.ReviewThreads`) and keys thread comments on it, so two comments
  on one thread dedup to a single wake. A webhook delivery carries the REST
  comment object, which has no thread id — only the comment's own `node_id`.
  This module asks GitHub for the one missing fact: the thread the comment
  hangs off, via `node(id: $commentNodeId)` selecting `pullRequestReviewThread`.

  Resolution is best-effort and fails open. When the delivery has no `node_id`,
  or the query errors or answers with something that is not a review comment,
  the caller keys per comment — the behaviour before this module existed. A
  duplicate wake is recoverable; a dropped delivery is not, so a failure must
  cost a possible extra wake, never a lost comment.
  """

  alias Aiur.GitHub.Transport

  @resolve_query """
  query AiurReviewThreadForComment($id: ID!) {
    node(id: $id) {
      ... on PullRequestReviewComment {
        pullRequestReviewThread {
          id
        }
      }
    }
  }
  """

  @doc """
  Returns the review-thread node id for `node_id` (a delivered review comment's
  GraphQL node id), or `:not_resolvable`.

  A query that answers with an error, a node that is not a
  `PullRequestReviewComment`, or no thread is `:not_resolvable` — never a crash
  and never a reason to drop the delivery.

  Options:

    * `:request_fun` — transport seam, passed to `Aiur.GitHub.Transport`; the
      default is the live GitHub transport.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | :not_resolvable
  def resolve(node_id, opts) when is_binary(node_id) and node_id != "" do
    do_resolve(node_id, opts)
  rescue
    _error -> :not_resolvable
  end

  def resolve(_node_id, _opts), do: :not_resolvable

  defp do_resolve(node_id, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

    with {:ok, token} <- Transport.require_token(opts),
         {:ok, body} <-
           Transport.github_graphql(
             request_fun,
             token,
             @resolve_query,
             %{"id" => node_id},
             caller: :webhook_review_thread
           ),
         thread_id when is_binary(thread_id) and thread_id != "" <-
           get_in(body, ["data", "node", "pullRequestReviewThread", "id"]) do
      {:ok, thread_id}
    else
      _other -> :not_resolvable
    end
  end
end
