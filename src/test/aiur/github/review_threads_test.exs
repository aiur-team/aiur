defmodule Aiur.GitHub.ReviewThreadsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{PollSnapshots, ResourceStore, ReviewThreads}

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
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    ResourceStore.reset()

    :ok
  end

  describe "normalize_pr_number/1" do
    test "accepts a positive integer" do
      assert {:ok, 42} = ReviewThreads.normalize_pr_number(42)
    end

    test "accepts a numeric string" do
      assert {:ok, 7} = ReviewThreads.normalize_pr_number("7")
    end

    test "rejects zero" do
      assert {:error, {:invalid_pr_number, 0}} = ReviewThreads.normalize_pr_number(0)
    end

    test "rejects a non-numeric string" do
      assert {:error, {:invalid_pr_number, "abc"}} = ReviewThreads.normalize_pr_number("abc")
    end
  end

  describe "fetch_unaddressed_pr_review_thread_comments/2" do
    test "serves a delivery-fresh complete collection without an upstream call" do
      repo_root = codeowners_repo!("src/owned.ts @owner\n")

      thread = %{
        "id" => "PRRT_delivery",
        "isResolved" => false,
        "updatedAt" => "2026-08-21T10:00:00Z",
        "path" => "src/owned.ts",
        "line" => 10,
        "comments" => %{"nodes" => [review_thread_comment(1, "owner", "please fix this")]}
      }

      assert :ok = PollSnapshots.put_review_threads("owner/repo", 61, [thread])
      assert :ok = PollSnapshots.merge_review_thread("owner/repo", 61, %{thread | "updatedAt" => "2026-08-21T10:01:00Z"})

      # Record rather than `flunk/1`: an exception raised inside `request_fun`
      # is swallowed by the transport's retry path and only surfaces when the
      # request deadline expires, so a regression would read in CI as a
      # multi-minute timeout instead of a failed assertion.
      test_pid = self()

      request_fun = fn _request ->
        send(test_pid, :unexpected_request)
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => nil}}}}}
      end

      assert {:ok, [comment]} =
               ReviewThreads.fetch_unaddressed_pr_review_thread_comments(61,
                 request_fun: request_fun,
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      refute_received :unexpected_request

      assert comment["review_thread_id"] == "PRRT_delivery"
      File.rm_rf!(repo_root)
    end

    test "a delivery-fresh collection does not require GitHub credentials" do
      System.delete_env("GITHUB_TOKEN")
      :persistent_term.erase(@token_cache_key)

      assert :ok =
               PollSnapshots.put_review_threads("owner/repo", 61, [
                 %{"id" => "PRRT_resolved", "isResolved" => false}
               ])

      assert :ok =
               PollSnapshots.merge_review_thread("owner/repo", 61, %{
                 "id" => "PRRT_resolved",
                 "isResolved" => true,
                 "updatedAt" => "2026-08-21T10:01:00Z"
               })

      assert {:ok, []} = ReviewThreads.fetch_unaddressed_pr_review_thread_comments(61)
    end

    test "writes a complete paid collection back with poll provenance" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn _request ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{
                 "pullRequest" => %{
                   "reviewThreads" => %{
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                     "nodes" => []
                   }
                 }
               }
             }
           }
         }}
      end

      assert {:ok, []} =
               ReviewThreads.fetch_unaddressed_pr_review_thread_comments(61,
                 request_fun: request_fun,
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      assert {:ok, %{source: :poll, data: %{"complete" => true, "threads" => []}}} =
               ResourceStore.fetch(PollSnapshots.review_threads_key("owner/repo", 61))

      File.rm_rf!(repo_root)
    end

    test "does not cache a partial collection when a cursor request fails" do
      pr_number = 61

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        case get_in(body, ["variables", "cursor"]) do
          nil ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "repository" => %{
                     "pullRequest" => %{
                       "reviewThreads" => %{
                         "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor_1"},
                         "nodes" => []
                       }
                     }
                   }
                 }
               }
             }}

          "cursor_1" ->
            {:error, :timeout}
        end
      end

      assert {:error, {:github, :timeout, %{reason: :timeout}}} =
               ReviewThreads.fetch_unaddressed_pr_review_thread_comments(pr_number,
                 request_fun: request_fun
               )

      assert ResourceStore.fetch(PollSnapshots.review_threads_key("owner/repo", pr_number)) == :miss
    end

    test "returns only unresolved threads' latest comments, CODEOWNERS-classified" do
      repo_root = codeowners_repo!("src/owned.ts @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        assert body["query"] =~ "AiurUnaddressedReviewThreads"
        assert body["variables"]["owner"] == "owner"
        assert body["variables"]["repo"] == "repo"
        assert body["variables"]["number"] == 61

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{
                 "pullRequest" => %{
                   "reviewThreads" => %{
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                     "nodes" => [
                       %{
                         "id" => "PRRT_unresolved",
                         "isResolved" => false,
                         "path" => "src/owned.ts",
                         "line" => 10,
                         "comments" => %{
                           "nodes" => [review_thread_comment(1, "owner", "please fix this")]
                         }
                       },
                       %{
                         "id" => "PRRT_resolved",
                         "isResolved" => true,
                         "path" => "src/owned.ts",
                         "line" => 11,
                         "comments" => %{
                           "nodes" => [review_thread_comment(2, "owner", "already resolved")]
                         }
                       }
                     ]
                   }
                 }
               }
             }
           }
         }}
      end

      assert {:ok, [comment]} =
               ReviewThreads.fetch_unaddressed_pr_review_thread_comments(61,
                 request_fun: request_fun,
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      assert comment["review_thread_id"] == "PRRT_unresolved"
      assert comment.authoritative

      File.rm_rf!(repo_root)
    end

    test "agent-authored latest comment surfaces with authoritative AND review_thread_resolution_required (FI-GH-029)" do
      repo_root = codeowners_repo!("* @owner\n")

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql"} ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{
                 "pullRequest" => %{
                   "reviewThreads" => %{
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                     "nodes" => [
                       %{
                         "id" => "PRRT_agent_replied",
                         "isResolved" => false,
                         "path" => "src/lib/foo.ex",
                         "line" => 5,
                         "comments" => %{
                           "nodes" => [
                             review_thread_comment(10, "owner", "please fix"),
                             review_thread_comment(11, "aiur-bot", "fixed!")
                           ]
                         }
                       }
                     ]
                   }
                 }
               }
             }
           }
         }}
      end

      assert {:ok, [comment]} =
               ReviewThreads.fetch_unaddressed_pr_review_thread_comments(1,
                 request_fun: request_fun,
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      assert comment["review_thread_id"] == "PRRT_agent_replied"
      assert comment.authoritative
      assert comment["review_thread_resolution_required"]

      File.rm_rf!(repo_root)
    end

    test "returns an error when team-backed CODEOWNER authority is unavailable during a quota hold" do
      repo_root = codeowners_repo!("* @acme/platform\n")

      request_fun = fn
        %{method: :post, url: "https://api.github.com/graphql"} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{
                   "pullRequest" => %{
                     "reviewThreads" => %{
                       "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                       "nodes" => [
                         %{
                           "id" => "PRRT_quota_hold",
                           "isResolved" => false,
                           "path" => "src/lib/foo.ex",
                           "line" => 5,
                           "comments" => %{
                             "nodes" => [review_thread_comment(12, "platform-owner", "please fix")]
                           }
                         }
                       ]
                     }
                   }
                 }
               }
             }
           }}

        %{method: :get, url: "https://api.github.com/orgs/acme/teams/platform/members?per_page=100"} ->
          {:ok, %{status: 429, body: %{}}}
      end

      assert {:error, :quota_hold} =
               ReviewThreads.fetch_unaddressed_pr_review_thread_comments(1,
                 request_fun: request_fun,
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      File.rm_rf!(repo_root)
    end

    test "still surfaces an agent-authored latest reply for required resolution during a quota hold" do
      repo_root = codeowners_repo!("* @acme/platform\n")

      request_fun = fn
        %{method: :post, url: "https://api.github.com/graphql"} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{
                   "pullRequest" => %{
                     "reviewThreads" => %{
                       "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                       "nodes" => [
                         %{
                           "id" => "PRRT_agent_quota_hold",
                           "isResolved" => false,
                           "path" => "src/lib/foo.ex",
                           "line" => 5,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(13, "platform-owner", "please fix"),
                               review_thread_comment(14, "aiur-bot", "fixed")
                             ]
                           }
                         }
                       ]
                     }
                   }
                 }
               }
             }
           }}

        %{method: :get, url: "https://api.github.com/orgs/acme/teams/platform/members?per_page=100"} ->
          {:ok, %{status: 429, body: %{}}}
      end

      assert {:ok, [comment]} =
               ReviewThreads.fetch_unaddressed_pr_review_thread_comments(1,
                 request_fun: request_fun,
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      assert comment.authoritative
      assert comment["review_thread_resolution_required"]

      File.rm_rf!(repo_root)
    end

    test "paginates across two pages via GraphQL cursor" do
      repo_root = codeowners_repo!("* @owner\n")
      {:ok, page_count} = Agent.start_link(fn -> 0 end)

      request_fun = fn %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        page = Agent.get_and_update(page_count, &{&1, &1 + 1})
        cursor = get_in(body, ["variables", "cursor"])

        case {page, cursor} do
          {0, nil} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "repository" => %{
                     "pullRequest" => %{
                       "reviewThreads" => %{
                         "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor_1"},
                         "nodes" => [
                           %{
                             "id" => "PRRT_page1",
                             "isResolved" => false,
                             "path" => "src/lib/foo.ex",
                             "line" => 1,
                             "comments" => %{
                               "nodes" => [review_thread_comment(100, "owner", "page 1")]
                             }
                           }
                         ]
                       }
                     }
                   }
                 }
               }
             }}

          {_, "cursor_1"} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "repository" => %{
                     "pullRequest" => %{
                       "reviewThreads" => %{
                         "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                         "nodes" => [
                           %{
                             "id" => "PRRT_page2",
                             "isResolved" => false,
                             "path" => "src/lib/foo.ex",
                             "line" => 2,
                             "comments" => %{
                               "nodes" => [review_thread_comment(101, "owner", "page 2")]
                             }
                           }
                         ]
                       }
                     }
                   }
                 }
               }
             }}
        end
      end

      assert {:ok, comments} =
               ReviewThreads.fetch_unaddressed_pr_review_thread_comments(1,
                 request_fun: request_fun,
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      assert Enum.map(comments, & &1["review_thread_id"]) == ["PRRT_page1", "PRRT_page2"]
      assert Agent.get(page_count, & &1) == 2

      File.rm_rf!(repo_root)
    end
  end

  defp codeowners_repo!(content) do
    repo_root = Path.join(System.tmp_dir!(), "aiur-rt-test-#{System.unique_integer([:positive])}")
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
end
