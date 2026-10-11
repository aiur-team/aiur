defmodule Aiur.GitHub.Client.ResolveReviewThreadTest do
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.GitHub.Client

  setup do
    setup_client()
  end

  describe "resolve_review_thread/2" do
    test "resolves a review thread with the GraphQL resolveReviewThread mutation" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_done", [
              review_thread_comment(701, "owner", "please verify"),
              review_thread_comment(702, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            assert body["variables"] == %{"threadId" => "PRRT_done"}

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "resolveReviewThread" => %{
                     "thread" => %{
                       "id" => "PRRT_done",
                       "isResolved" => true
                     }
                   }
                 }
               }
             }}
        end
      end

      assert {:ok, result} =
               Client.resolve_review_thread("PRRT_done",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      assert result.resolved
      assert result.review_thread_id == "PRRT_done"
      assert get_in(result.verification, ["latest_comment", "user", "login"]) == "aiur-bot"

      File.rm_rf!(repo_root)
    end

    test "fails after resolving when a reviewer follow-up becomes latest in the resolve window" do
      repo_root = codeowners_repo!("* @owner\n")
      {:ok, query_count} = Agent.start_link(fn -> 0 end)
      {:ok, unresolve_count} = Agent.start_link(fn -> 0 end)

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            case Agent.get_and_update(query_count, &{&1, &1 + 1}) do
              0 ->
                review_thread_node_response("PRRT_raced", [
                  review_thread_comment(711, "owner", "please verify"),
                  review_thread_comment(712, "aiur-bot", "Done, no further changes.")
                ])

              1 ->
                review_thread_node_response(
                  "PRRT_raced",
                  [
                    review_thread_comment(711, "owner", "please verify"),
                    review_thread_comment(712, "aiur-bot", "Done, no further changes."),
                    review_thread_comment(713, "owner", "Actually, please also fix this.")
                  ],
                  %{"isResolved" => true}
                )
            end

          body["query"] =~ "unresolveReviewThread" ->
            Agent.update(unresolve_count, &(&1 + 1))
            assert body["variables"] == %{"threadId" => "PRRT_raced"}

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "unresolveReviewThread" => %{
                     "thread" => %{
                       "id" => "PRRT_raced",
                       "isResolved" => false
                     }
                   }
                 }
               }
             }}

          body["query"] =~ "resolveReviewThread" ->
            assert body["variables"] == %{"threadId" => "PRRT_raced"}

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "resolveReviewThread" => %{
                     "thread" => %{
                       "id" => "PRRT_raced",
                       "isResolved" => true
                     }
                   }
                 }
               }
             }}
        end
      end

      assert {:error,
              {:review_thread_resolution_precondition_failed,
               %{
                 reason: :post_resolve_latest_comment_author_mismatch,
                 review_thread_id: "PRRT_raced",
                 latest_comment: %{"body" => "Actually, please also fix this."},
                 unresolved_after_post_resolve_mismatch: %{
                   review_thread_id: "PRRT_raced",
                   mutation_response: %{
                     "data" => %{
                       "unresolveReviewThread" => %{
                         "thread" => %{
                           "id" => "PRRT_raced",
                           "isResolved" => false
                         }
                       }
                     }
                   }
                 }
               }}} =
               Client.resolve_review_thread("PRRT_raced",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      assert Agent.get(query_count, & &1) == 2
      assert Agent.get(unresolve_count, & &1) == 1

      File.rm_rf!(repo_root)
    end

    test "classifies resolve permission failures with required token guidance" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_denied", [
              review_thread_comment(801, "owner", "please verify"),
              review_thread_comment(802, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "errors" => [
                   %{"message" => "Resource not accessible by personal access token", "type" => "FORBIDDEN"}
                 ]
               }
             }}
        end
      end

      assert {:error,
              {:review_thread_resolution_not_permitted,
               %{
                 review_thread_id: "PRRT_denied",
                 errors: [%{"message" => "Resource not accessible by personal access token"}],
                 required_permission: required_permission
               }}} =
               Client.resolve_review_thread("PRRT_denied",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      assert required_permission =~ "Pull requests: Read and write"

      File.rm_rf!(repo_root)
    end

    test "does not classify unrelated GraphQL errors as token permission failures" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_error", [
              review_thread_comment(811, "owner", "please verify"),
              review_thread_comment(812, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            {:ok,
             %{
               status: 200,
               body: %{"errors" => [%{"message" => "not permitted on an already resolved thread"}]}
             }}
        end
      end

      assert {:error, {:github_graphql_errors, [%{"message" => "not permitted on an already resolved thread"}]}} =
               Client.resolve_review_thread("PRRT_error",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      File.rm_rf!(repo_root)
    end

    test "fails when the mutation does not report a resolved thread" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_still_open", [
              review_thread_comment(901, "owner", "please verify"),
              review_thread_comment(902, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "resolveReviewThread" => %{
                     "thread" => %{
                       "id" => "PRRT_still_open",
                       "isResolved" => false
                     }
                   }
                 }
               }
             }}
        end
      end

      assert {:error, {:review_thread_not_resolved, %{review_thread_id: "PRRT_still_open"}}} =
               Client.resolve_review_thread("PRRT_still_open",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      File.rm_rf!(repo_root)
    end

    test "refuses to resolve when the terminal reply is no longer the latest comment" do
      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_followup", [
              review_thread_comment(1001, "owner", "please verify"),
              review_thread_comment(1002, "aiur-bot", "Done, no further changes."),
              review_thread_comment(1003, "owner", "Actually, please also fix this.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            flunk("resolveReviewThread must not be called when a reviewer follow-up is latest")
        end
      end

      assert {:error,
              {:review_thread_resolution_precondition_failed,
               %{
                 reason: :latest_comment_author_mismatch,
                 review_thread_id: "PRRT_followup"
               }}} =
               Client.resolve_review_thread("PRRT_followup",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes."
               )
    end

    test "refuses to resolve when the reviewer is outside the CODEOWNERS trust boundary" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_nonowner", [
              review_thread_comment(1101, "guest", "please verify"),
              review_thread_comment(1102, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            flunk("resolveReviewThread must not be called for non-authoritative reviewer threads")
        end
      end

      assert {:error, {:review_thread_resolution_not_authorized, %{review_thread_id: "PRRT_nonowner", path: "src/lib/aiur/github/client.ex"}}} =
               Client.resolve_review_thread("PRRT_nonowner",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      File.rm_rf!(repo_root)
    end
  end
end
