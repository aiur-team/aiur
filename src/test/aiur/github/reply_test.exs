defmodule Aiur.GitHub.ReviewThreads.ReplyTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.ReviewThreads.Reply

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    :ok
  end

  describe "reply_to_review_thread/3" do
    test "verified first-try reply returns {:ok, _}" do
      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "addPullRequestReviewThreadReply" => %{
                     "comment" => review_thread_comment(2, "aiur-bot", "Done.")
                   }
                 }
               }
             }}

          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_ok", [
              review_thread_comment(1, "owner", "please fix"),
              review_thread_comment(2, "aiur-bot", "Done.")
            ])
        end
      end

      assert {:ok, result} =
               Reply.reply_to_review_thread("PRRT_ok", "Done.",
                 request_fun: request_fun,
                 bot_account: "aiur-bot",
                 retry_delay_ms: 0
               )

      assert result.verified
      assert result.review_thread_id == "PRRT_ok"
    end

    test "retries verification without posting duplicate replies (FI-GH-030)" do
      {:ok, counts} = Agent.start_link(fn -> %{mutation: 0, query: 0} end)

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            Agent.update(counts, fn s -> Map.update!(s, :mutation, fn n -> n + 1 end) end)

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "addPullRequestReviewThreadReply" => %{
                     "comment" => review_thread_comment(2, "aiur-bot", "Done.")
                   }
                 }
               }
             }}

          body["query"] =~ "query AiurReviewThread" ->
            query_count = Agent.get_and_update(counts, fn s -> {s.query + 1, %{s | query: s.query + 1}} end)

            comments =
              if query_count == 1 do
                [review_thread_comment(1, "owner", "please fix")]
              else
                [
                  review_thread_comment(1, "owner", "please fix"),
                  review_thread_comment(2, "aiur-bot", "Done.")
                ]
              end

            review_thread_node_response("PRRT_retry", comments)
        end
      end

      assert {:ok, %{attempt: 2}} =
               Reply.reply_to_review_thread("PRRT_retry", "Done.",
                 request_fun: request_fun,
                 bot_account: "aiur-bot",
                 attempts: 3,
                 retry_delay_ms: 0
               )

      # Mutation posted exactly once; only verification retried
      assert Agent.get(counts, & &1) == %{mutation: 1, query: 2}
    end

    test "retryable transport error on the mutation retries up to attempts" do
      {:ok, call_count} = Agent.start_link(fn -> 0 end)

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            Agent.update(call_count, &(&1 + 1))
            {:error, %Req.TransportError{reason: :timeout}}

          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_transport", [])
        end
      end

      assert {:error, _} =
               Reply.reply_to_review_thread("PRRT_transport", "Done.",
                 request_fun: request_fun,
                 bot_account: "aiur-bot",
                 attempts: 2,
                 retry_delay_ms: 0
               )

      assert Agent.get(call_count, & &1) == 2
    end

    test "final verify failure returns review_thread_reply_not_verified error" do
      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "addPullRequestReviewThreadReply" => %{
                     "comment" => review_thread_comment(2, "aiur-bot", "Done.")
                   }
                 }
               }
             }}

          body["query"] =~ "query AiurReviewThread" ->
            # Always return a different latest comment so verification never passes
            review_thread_node_response("PRRT_fail", [
              review_thread_comment(1, "owner", "please fix"),
              review_thread_comment(3, "owner", "still latest — not the bot's reply")
            ])
        end
      end

      assert {:error, {:review_thread_reply_not_verified, %{published_comment: %{"id" => 2}}}} =
               Reply.reply_to_review_thread("PRRT_fail", "Done.",
                 request_fun: request_fun,
                 bot_account: "aiur-bot",
                 attempts: 1,
                 retry_delay_ms: 0
               )
    end

    test "sleep_fun is injectable and called with linear backoff" do
      parent = self()

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "addPullRequestReviewThreadReply" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "addPullRequestReviewThreadReply" => %{
                     "comment" => review_thread_comment(2, "aiur-bot", "Done.")
                   }
                 }
               }
             }}

          body["query"] =~ "query AiurReviewThread" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "node" => %{
                     "id" => "PRRT_sleep",
                     "isResolved" => false,
                     "path" => "src/lib/foo.ex",
                     "line" => 1,
                     "comments" => %{
                       "nodes" => [
                         review_thread_comment(3, "owner", "still there")
                       ]
                     }
                   }
                 }
               }
             }}
        end
      end

      sleep_fun = fn ms -> send(parent, {:sleep, ms}) end

      Reply.reply_to_review_thread("PRRT_sleep", "Done.",
        request_fun: request_fun,
        bot_account: "aiur-bot",
        attempts: 2,
        retry_delay_ms: 50,
        sleep_fun: sleep_fun
      )

      assert_received {:sleep, 50}
    end
  end

  defp review_thread_comment(id, login, body) do
    %{
      "id" => "PRRC_#{id}",
      "databaseId" => id,
      "body" => body,
      "createdAt" => "2026-06-25T04:13:21Z",
      "updatedAt" => "2026-06-25T04:13:21Z",
      "url" => "https://github.test/discussion_r#{id}",
      "author" => %{"login" => login}
    }
  end

  defp review_thread_node_response(thread_id, comments) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "node" => %{
             "id" => thread_id,
             "isResolved" => false,
             "path" => "src/lib/aiur/github/client.ex",
             "line" => 12,
             "comments" => %{"nodes" => comments}
           }
         }
       }
     }}
  end
end
