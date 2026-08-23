defmodule Aiur.GitHub.ReviewThreads.ResolutionTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.ReviewThreads.Resolution

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

  describe "resolve_review_thread/2" do
    test "clean resolve returns {:ok, _}" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_clean", [
              review_thread_comment(1, "owner", "please fix"),
              review_thread_comment(2, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "resolveReviewThread" => %{
                     "thread" => %{
                       "id" => "PRRT_clean",
                       "isResolved" => true
                     }
                   }
                 }
               }
             }}
        end
      end

      assert {:ok, result} =
               Resolution.resolve_review_thread("PRRT_clean",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      assert result.resolved
      assert result.review_thread_id == "PRRT_clean"

      File.rm_rf!(repo_root)
    end

    test "reviewer comment in the resolve window triggers compensating unresolve (TOCTOU FI-GH-031)" do
      repo_root = codeowners_repo!("* @owner\n")
      {:ok, query_count} = Agent.start_link(fn -> 0 end)
      {:ok, unresolve_count} = Agent.start_link(fn -> 0 end)

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            case Agent.get_and_update(query_count, &{&1, &1 + 1}) do
              0 ->
                review_thread_node_response("PRRT_raced", [
                  review_thread_comment(1, "owner", "please fix"),
                  review_thread_comment(2, "aiur-bot", "Done, no further changes.")
                ])

              1 ->
                review_thread_node_response(
                  "PRRT_raced",
                  [
                    review_thread_comment(1, "owner", "please fix"),
                    review_thread_comment(2, "aiur-bot", "Done, no further changes."),
                    review_thread_comment(3, "owner", "Actually, please also fix this.")
                  ],
                  %{"isResolved" => true}
                )
            end

          body["query"] =~ "unresolveReviewThread" ->
            Agent.update(unresolve_count, &(&1 + 1))

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "unresolveReviewThread" => %{
                     "thread" => %{"id" => "PRRT_raced", "isResolved" => false}
                   }
                 }
               }
             }}

          body["query"] =~ "resolveReviewThread" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "resolveReviewThread" => %{
                     "thread" => %{"id" => "PRRT_raced", "isResolved" => true}
                   }
                 }
               }
             }}
        end
      end

      error_key = :review_thread_resolution_precondition_failed

      assert {:error, {^error_key, %{reason: :post_resolve_latest_comment_author_mismatch}}} =
               Resolution.resolve_review_thread("PRRT_raced",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      assert Agent.get(unresolve_count, & &1) == 1

      File.rm_rf!(repo_root)
    end

    test "FORBIDDEN mutation classifies as :review_thread_resolution_not_permitted with token guidance (FI-GH-031)" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        cond do
          body["query"] =~ "query AiurReviewThread" ->
            review_thread_node_response("PRRT_denied", [
              review_thread_comment(1, "owner", "please fix"),
              review_thread_comment(2, "aiur-bot", "Done, no further changes.")
            ])

          body["query"] =~ "resolveReviewThread" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "errors" => [
                   %{
                     "message" => "Resource not accessible by personal access token",
                     "type" => "FORBIDDEN"
                   }
                 ]
               }
             }}
        end
      end

      assert {:error,
              {:review_thread_resolution_not_permitted,
               %{
                 review_thread_id: "PRRT_denied",
                 required_permission: required_permission
               }}} =
               Resolution.resolve_review_thread("PRRT_denied",
                 request_fun: request_fun,
                 daemon_account: "aiur-bot",
                 terminal_reply_body: "Done, no further changes.",
                 repo_root: repo_root
               )

      assert required_permission =~ "Pull requests"

      File.rm_rf!(repo_root)
    end
  end

  defp codeowners_repo!(content) do
    repo_root =
      Aiur.TestSupport.tmp_root!("aiur-res-test")

    path = Path.join(repo_root, ".github/CODEOWNERS")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    repo_root
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

  defp review_thread_node_response(thread_id, comments, attrs \\ %{}) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "node" =>
             Map.merge(
               %{
                 "id" => thread_id,
                 "isResolved" => false,
                 "path" => "src/lib/aiur/github/client.ex",
                 "line" => 12,
                 "comments" => %{"nodes" => comments}
               },
               attrs
             )
         }
       }
     }}
  end
end
