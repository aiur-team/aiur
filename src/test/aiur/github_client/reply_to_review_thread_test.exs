defmodule Aiur.GitHub.Client.ReplyToReviewThreadTest do
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.GitHub.Client

  setup do
    setup_client()
  end

  describe "reply_to_review_thread/3" do
    test "posts a review thread reply and verifies it is the latest bot-authored comment" do
      request_fun = fn
        %{method: :post, url: "https://api.github.com/graphql", body: body} ->
          cond do
            body["query"] =~ "addPullRequestReviewThreadReply" ->
              assert body["variables"] == %{
                       "threadId" => "PRRT_verified",
                       "body" => "Verified this is already fixed."
                     }

              {:ok,
               %{
                 status: 200,
                 body: %{
                   "data" => %{
                     "addPullRequestReviewThreadReply" => %{
                       "comment" => review_thread_comment(202, "aiur-bot", "Verified this is already fixed.")
                     }
                   }
                 }
               }}

            body["query"] =~ "query AiurReviewThread" ->
              assert body["variables"] == %{"id" => "PRRT_verified"}

              review_thread_node_response("PRRT_verified", [
                review_thread_comment(201, "owner", "please verify"),
                review_thread_comment(202, "aiur-bot", "Verified this is already fixed.")
              ])
          end
      end

      assert {:ok, result} =
               Client.reply_to_review_thread("PRRT_verified", "Verified this is already fixed.",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 retry_delay_ms: 0
               )

      assert result.verified
      assert result.review_thread_id == "PRRT_verified"
      assert get_in(result.verification, ["latest_comment", "user", "login"]) == "aiur-bot"
    end

    test "preserves GraphQL errors from the reply mutation" do
      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        assert body["query"] =~ "addPullRequestReviewThreadReply"

        {:ok,
         %{
           status: 200,
           body: %{"errors" => [%{"message" => "Could not resolve to a node"}]}
         }}
      end

      assert {:error, {:github_graphql_errors, [%{"message" => "Could not resolve to a node"}]}} =
               Client.reply_to_review_thread("PRRT_missing", "reply",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 retry_delay_ms: 0
               )
    end

    test "retries verification without posting duplicate replies" do
      {:ok, counts} = Agent.start_link(fn -> %{mutation: 0, query: 0} end)

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            Agent.update(counts, &Map.update!(&1, :mutation, fn count -> count + 1 end))

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "addPullRequestReviewThreadReply" => %{
                     "comment" => review_thread_comment(302, "aiur-bot", "Fixed on this branch.")
                   }
                 }
               }
             }}

          body["query"] =~ "query AiurReviewThread" ->
            query_count =
              Agent.get_and_update(counts, fn state ->
                next = state.query + 1
                {next, %{state | query: next}}
              end)

            comments =
              if query_count == 1 do
                [review_thread_comment(301, "owner", "still latest")]
              else
                [
                  review_thread_comment(301, "owner", "still latest"),
                  review_thread_comment(302, "aiur-bot", "Fixed on this branch.")
                ]
              end

            review_thread_node_response("PRRT_retry", comments)
        end
      end

      assert {:ok, %{attempt: 2}} =
               Client.reply_to_review_thread("PRRT_retry", "Fixed on this branch.",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 attempts: 2,
                 retry_delay_ms: 0
               )

      assert Agent.get(counts, & &1) == %{mutation: 1, query: 2}
    end

    test "falls back to the authenticated viewer login when no daemon identity is configured" do
      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "addPullRequestReviewThreadReply" => %{
                     "comment" => review_thread_comment(402, "its-everdred", "Verified by body.")
                   }
                 }
               }
             }}

          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_viewer", [
              review_thread_comment(401, "its-everdred", "please verify"),
              review_thread_comment(402, "its-everdred", "Verified by body.")
            ])

          body["query"] =~ "query AiurViewerLogin" ->
            {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "its-everdred"}}}}}
        end
      end

      assert {:ok, result} =
               Client.reply_to_review_thread("PRRT_viewer", "Verified by body.",
                 request_fun: request_fun,
                 retry_delay_ms: 0
               )

      assert result.verified
      assert get_in(result.verification, ["latest_comment", "user", "login"]) == "its-everdred"
      assert get_in(result.verification, ["latest_comment", "body"]) == "Verified by body."
    end

    test "fails verification when the reviewer remains latest across all retries" do
      {:ok, counts} = Agent.start_link(fn -> %{mutation: 0, query: 0} end)

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            Agent.update(counts, &Map.update!(&1, :mutation, fn count -> count + 1 end))

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "addPullRequestReviewThreadReply" => %{
                     "comment" => review_thread_comment(502, "aiur-bot", "Fixed on this branch.")
                   }
                 }
               }
             }}

          body["query"] =~ "query AiurReviewThread" ->
            Agent.update(counts, &Map.update!(&1, :query, fn count -> count + 1 end))

            review_thread_node_response("PRRT_stale", [
              review_thread_comment(501, "owner", "still latest")
            ])
        end
      end

      assert {:error,
              {:review_thread_reply_not_verified,
               %{
                 attempts: 3,
                 review_thread_id: "PRRT_stale",
                 reason: {:review_thread_latest_comment_author_mismatch, %{actual: "owner", expected: "aiur-bot"}}
               }}} =
               Client.reply_to_review_thread("PRRT_stale", "Fixed on this branch.",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 attempts: 3,
                 retry_delay_ms: 0
               )

      assert Agent.get(counts, & &1) == %{mutation: 1, query: 3}
    end
  end
end
