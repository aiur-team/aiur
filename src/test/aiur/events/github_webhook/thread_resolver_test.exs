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
