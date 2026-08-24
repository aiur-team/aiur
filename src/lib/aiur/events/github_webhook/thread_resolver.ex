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

  Before spending that GraphQL point it consults the comment→thread map the
  poller's batch already parsed (`Aiur.GitHub.CommentPollBatch` deposits every
  `reviewThreads { comments { databaseId } }` mapping it reads into
  `:pr_review_comment_thread`). A delivery whose comment the batch has already
  seen resolves for free (#2326). The map is keyed by the comment's REST
  `databaseId`, which the delivery carries alongside the `node_id`, so the
  caller passes it through the options.

  Resolution is best-effort and fails open. When the delivery has no `node_id`,
  the map holds nothing, or the query errors or answers with something that is
  not a review comment, the caller keys per comment — the behaviour before this
  module existed. A duplicate wake is recoverable; a dropped delivery is not, so
  a failure must cost a possible extra wake, never a lost comment.
  """

  alias Aiur.GitHub.{ResourceStore, Transport}

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
    * `:repo` — the tracked `"owner/name"` the delivery belongs to, and
      `:comment_id` — the delivered comment's REST `databaseId`. Both let the
      resolver consult the poller-built comment→thread map before the GraphQL
      call; when either is absent the map is skipped and the query is used.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | :not_resolvable
  def resolve(node_id, opts) when is_binary(node_id) and node_id != "" do
    case stored_thread(opts) do
      {:ok, thread_id} -> {:ok, thread_id}
      :not_resolvable -> do_resolve(node_id, opts)
    end
  rescue
    _error -> :not_resolvable
  end

  def resolve(_node_id, _opts), do: :not_resolvable

  # The poller-built mapping: comment `databaseId` → thread node id. A comment's
  # thread never changes, so a mapping the batch already parsed is as good as a
  # fresh query and costs nothing. Keyed by `:comment_id` — the delivery's REST
  # id, which is the batch's `databaseId`, an integer.
  defp stored_thread(opts) do
    with comment_id
         when is_integer(comment_id) or (is_binary(comment_id) and comment_id != "") <-
           Keyword.get(opts, :comment_id),
         repo when is_binary(repo) and repo != "" <- Keyword.get(opts, :repo),
         key when not is_nil(key) <- ResourceStore.key_for_repo(:pr_review_comment_thread, repo, comment_id),
         {:ok, %{data: thread_id}} when is_binary(thread_id) and thread_id != "" <- ResourceStore.fetch(key) do
      {:ok, thread_id}
    else
      _other -> :not_resolvable
    end
  end

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
