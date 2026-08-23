defmodule Aiur.Events.GithubWebhook.ThreadResolverTest do
  @moduledoc """
  `Aiur.Events.GithubWebhook.ThreadResolver` turns a delivered review comment's
  own GraphQL `node_id` into the review-thread node id it belongs to — the one
  fact a `pull_request_review_comment` delivery does not carry, and the fact
  that lets the webhook pipe key inline feedback on the thread the way the
  poller does (#2081).
  """

  use Aiur.TestSupport

  alias Aiur.Events.GithubWebhook.ThreadResolver
  alias Aiur.GitHub.ResourceStore

  setup do
    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  test "resolves a review comment node id to its thread id" do
    request_fun = fn %{body: %{"variables" => %{"id" => "PRRC_kwDOabc123"}}} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "node" => %{"pullRequestReviewThread" => %{"id" => "PRRT_kwDOabc123"}}
           }
         }
       }}
    end

    assert {:ok, "PRRT_kwDOabc123"} = ThreadResolver.resolve("PRRC_kwDOabc123", request_fun: request_fun)
  end

  # Acceptance #2326: the resolver consults the comment→thread map the poller's
  # batch already built before spending a GraphQL point. A comment the batch has
  # seen resolves with zero upstream calls.
  test "answers from the poller-built comment→thread map without calling the transport" do
    :pr_review_comment_thread
    |> ResourceStore.key_for_repo("owner/repo", 9_101)
    |> ResourceStore.put_resource("PRRT_kwDOabc123", source: :poll)

    assert {:ok, "PRRT_kwDOabc123"} =
             ThreadResolver.resolve("PRRC_kwDOabc123",
               repo: "owner/repo",
               comment_id: 9_101,
               request_fun: fn _request -> flunk("the map must answer before any GraphQL call") end
             )
  end

  test "falls back to the GraphQL lookup when the map has no entry" do
    request_fun = fn %{body: %{"variables" => %{"id" => "PRRC_kwDOabc123"}}} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{"node" => %{"pullRequestReviewThread" => %{"id" => "PRRT_kwDOabc123"}}}
         }
       }}
    end

    assert {:ok, "PRRT_kwDOabc123"} =
             ThreadResolver.resolve("PRRC_kwDOabc123",
               repo: "owner/repo",
               comment_id: 9_999,
               request_fun: request_fun
             )
  end

  test "answers :not_resolvable when the node is not a review comment" do
    request_fun = fn _request -> {:ok, %{status: 200, body: %{"data" => %{"node" => %{"id" => "PR_other"}}}}} end

    assert :not_resolvable = ThreadResolver.resolve("PRRC_kwDOabc123", request_fun: request_fun)
  end

  test "answers :not_resolvable when the lookup errors" do
    request_fun = fn _request -> {:error, :network} end

    assert :not_resolvable = ThreadResolver.resolve("PRRC_kwDOabc123", request_fun: request_fun)
  end

  test "answers :not_resolvable without ever calling the transport when there is no node id" do
    assert :not_resolvable = ThreadResolver.resolve("", request_fun: fn _request -> flunk("transport must not be called") end)
    assert :not_resolvable = ThreadResolver.resolve(nil, request_fun: fn _request -> flunk("transport must not be called") end)
  end
end
