defmodule Aiur.GitHub.Client.IssueStateTest do
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.GitHub.Client

  setup do
    setup_client()
  end

  describe "update_issue_state/3" do
    test "swaps labels and closes terminal issues" do
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          # GET issue
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:todo"}, %{"name" => "other"}]
               }
             }}

          # POST new label (terminal target, so no active-label re-check GET)
          {:post, 1} ->
            assert req.body == %{"labels" => ["sym:done"]}
            {:ok, %{status: 200}}

          # DELETE old label (new label excluded)
          {:delete, 2} ->
            assert req.url =~ "sym:todo" or req.url =~ "sym%3Atodo"
            {:ok, %{status: 200}}

          # PATCH close
          {:patch, 3} ->
            assert req.body == %{"state" => "closed"}
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = Client.update_issue_state("42", "Done", request_fun: request_fun)
    end

    test "state swaps preserve paused and watch marker labels" do
      test_pid = self()
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        send(test_pid, {:github_request, req})
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [
                   %{"name" => "sym:paused"},
                   %{"name" => "sym:todo"},
                   %{"name" => "sym:watch"}
                 ]
               }
             }}

          {:get, 1} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [
                   %{"name" => "sym:paused"},
                   %{"name" => "sym:todo"},
                   %{"name" => "sym:watch"}
                 ]
               }
             }}

          {:post, 2} ->
            assert req.body == %{"labels" => ["sym:rework"]}
            {:ok, %{status: 200}}

          {:delete, 3} ->
            assert req.url =~ "sym:todo" or req.url =~ "sym%3Atodo"
            {:ok, %{status: 200}}
        end
      end

      assert :ok = Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}, 1000
      assert_receive {:github_request, %{method: :get}}, 1000
      assert_receive {:github_request, %{method: :post, body: %{"labels" => ["sym:rework"]}}}, 1000
      assert_receive {:github_request, %{method: :delete, url: deleted_url}}, 1000
      refute deleted_url =~ "sym:paused"
      refute deleted_url =~ "sym:watch"
      refute_receive {:github_request, %{method: :delete}}, 100
    end

    test "human-review readiness requires unresolved authenticated-viewer replies to be resolved" do
      repo_root = codeowners_repo!("* @its-everdred\n")
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:github_request, req})

        cond do
          # No standing approval on this PR, so the #1756 approval override
          # does not apply and the unresolved thread still blocks.
          req.method == :get and req.url =~ "/pulls/77/reviews" ->
            {:ok, %{status: 200, body: []}}

          req.method == :get and req.url =~ "/pulls?" ->
            {:ok, %{status: 200, body: [%{"number" => 77, "head" => %{"ref" => "aiur/42"}}]}}

          req.method == :post and req.body["query"] =~ "query AiurViewerLogin" ->
            {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "its-everdred"}}}}}

          req.method == :post and req.body["query"] =~ "AiurUnaddressedReviewThreads" ->
            review_threads_page_response([
              %{
                "id" => "PRRT_self_reply",
                "isResolved" => false,
                "path" => "src/lib/aiur/github/client.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(601, "its-everdred", "Verified on this branch.")
                  ]
                }
              }
            ])
        end
      end

      assert {:error, {:unverified_review_threads, %{count: 1, pr_number: 77, review_thread_ids: ["PRRT_self_reply"]}}} =
               Client.verify_human_review_ready("42",
                 request_fun: request_fun,
                 repo_root: repo_root,
                 bot_account: nil
               )

      assert_receive {:github_request, %{method: :get, url: pulls_url}}, 1000
      assert pulls_url =~ "/pulls?"
      assert_receive {:github_request, %{method: :post, body: %{"query" => viewer_query}}}, 1000
      assert viewer_query =~ "AiurViewerLogin"
      assert_receive {:github_request, %{method: :post, body: %{"query" => threads_query}}}, 1000
      assert threads_query =~ "AiurUnaddressedReviewThreads"

      File.rm_rf!(repo_root)
    end

    test "human-review readiness allows authenticated-viewer replies when the thread is resolved" do
      repo_root = codeowners_repo!("* @its-everdred\n")

      request_fun = fn req ->
        cond do
          req.method == :get and req.url =~ "/compare/main...tested-head" ->
            {:ok, %{status: 200, body: %{"status" => "ahead"}}}

          req.method == :get and req.url =~ "/pulls?" ->
            {:ok, %{status: 200, body: [%{"number" => 77, "head" => %{"ref" => "aiur/42", "sha" => "tested-head"}}]}}

          req.method == :post and req.body["query"] =~ "query AiurViewerLogin" ->
            {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "its-everdred"}}}}}

          req.method == :post and req.body["query"] =~ "AiurUnaddressedReviewThreads" ->
            review_threads_page_response([
              %{
                "id" => "PRRT_self_reply",
                "isResolved" => true,
                "path" => "src/lib/aiur/github/client.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(601, "its-everdred", "Verified on this branch.")
                  ]
                }
              }
            ])
        end
      end

      assert :ok =
               Client.verify_human_review_ready("42",
                 request_fun: request_fun,
                 repo_root: repo_root,
                 bot_account: nil
               )

      File.rm_rf!(repo_root)
    end

    test "refuses human-review while authoritative review threads remain unverified" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:github_request, req})

        cond do
          req.method == :get and req.url =~ "/issues/42" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:in-progress"}]
               }
             }}

          # No standing approval, so the #1756 approval override does not apply.
          req.method == :get and req.url =~ "/pulls/77/reviews" ->
            {:ok, %{status: 200, body: []}}

          req.method == :get and req.url =~ "/pulls?" ->
            {:ok, %{status: 200, body: [%{"number" => 77, "head" => %{"ref" => "aiur/42"}}]}}

          req.method == :post and req.url == "https://api.github.com/graphql" ->
            review_threads_page_response([
              %{
                "id" => "PRRT_blocking",
                "isResolved" => false,
                "path" => "src/lib/aiur/github/client.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(401, "its-everdred", "please verify this exact thread")
                  ]
                }
              }
            ])
        end
      end

      assert {:error, {:unverified_review_threads, %{count: 1, pr_number: 77, review_thread_ids: ["PRRT_blocking"]}}} =
               Client.update_issue_state("42", "human-review",
                 request_fun: request_fun,
                 bot_account: "aiur-bot"
               )

      assert_receive {:github_request, %{method: :get}}, 1000
      assert_receive {:github_request, %{method: :get, url: pulls_url}}, 1000
      assert pulls_url =~ "/repos/owner/repo/pulls?"
      assert pulls_url =~ "state=open"
      # The `head=` probe is gone: the listing's own branch filter already
      # covered every branch spelling it could match, so it was a second billed
      # request per lookup that answered nothing new.
      refute pulls_url =~ "head="
      assert_receive {:github_request, %{method: :post, url: "https://api.github.com/graphql"}}, 1000
      refute_receive {:github_request, %{method: :delete}}, 100

      refute_receive {:github_request, %{method: :post, body: %{"labels" => ["sym:human-review"]}}},
                     100
    end

    test "allows human-review when the open PR has no unaddressed review threads" do
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:in-progress"}]
               }
             }}

          {:get, 1} ->
            assert req.url =~ "/pulls?"
            {:ok, %{status: 200, body: [%{"number" => 77, "head" => %{"ref" => "aiur/42", "sha" => "tested-head"}}]}}

          {:post, 2} ->
            assert req.url == "https://api.github.com/graphql"
            review_threads_page_response([])

          # The swap adds first: the active-label add re-checks the issue, then
          # POSTs the new label, then removes the old one (#2420).
          {:get, 3} ->
            assert req.url =~ "/compare/main...tested-head"
            {:ok, %{status: 200, body: %{"status" => "ahead"}}}

          {:get, 4} ->
            assert req.url =~ "/issues/42"

            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:in-progress"}]
               }
             }}

          {:post, 5} ->
            assert req.body == %{"labels" => ["sym:human-review"]}
            {:ok, %{status: 200}}

          {:delete, 6} ->
            assert req.url =~ "sym:in-progress" or req.url =~ "sym%3Ain-progress"
            {:ok, %{status: 200}}
        end
      end

      assert :ok =
               Client.update_issue_state("42", "human-review",
                 request_fun: request_fun,
                 bot_account: "aiur-bot"
               )
    end

    test "closed issues remove stale active labels and report no state label written" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:github_request, req})

        case req.method do
          :get ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [
                   %{"name" => "sym:done"},
                   %{"name" => "sym:human-review"},
                   %{"name" => "sym:rework"},
                   %{"name" => "other"}
                 ]
               }
             }}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      # Active target on a closed issue: the stale active labels are stripped,
      # but no active state label was written, so the transition reports that
      # honestly instead of a false `:ok` (#2420).
      assert {:error, {:no_state_label_written, _issue}} =
               Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}, 1000
      assert_receive {:github_request, %{method: :delete, url: human_review_url}}, 1000
      assert_receive {:github_request, %{method: :delete, url: rework_url}}, 1000
      refute human_review_url =~ "sym:done"
      refute rework_url =~ "sym:done"
      refute_receive {:github_request, %{method: :post}}, 100
      refute_receive {:github_request, %{method: :patch}}, 100

      assert human_review_url =~ "sym:human-review" or human_review_url =~ "sym%3Ahuman-review"
      assert rework_url =~ "sym:rework" or rework_url =~ "sym%3Arework"
    end

    test "active label add rechecks issue state after stale label removal" do
      test_pid = self()
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        send(test_pid, {:github_request, req})
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:human-review"}]
               }
             }}

          {:get, 1} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [%{"name" => "sym:done"}, %{"name" => "sym:rework"}]
               }
             }}

          {:delete, 2} ->
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      # The add is the swap's first step; its closed-state re-check finds the
      # issue closed, strips the stale active label, and reports that no state
      # label was written (#2420).
      assert {:error, {:no_state_label_written, _issue}} =
               Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}, 1000
      assert_receive {:github_request, %{method: :get}}, 1000
      assert_receive {:github_request, %{method: :delete, url: rework_url}}, 1000
      refute rework_url =~ "sym:done"
      refute_receive {:github_request, %{method: :post}}, 100
      refute_receive {:github_request, %{method: :patch}}, 100

      assert rework_url =~ "sym:rework" or rework_url =~ "sym%3Arework"
    end

    test "closed issue active-label cleanup reports delete failures" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:github_request, req})

        case req.method do
          :get ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [%{"name" => "sym:human-review"}]
               }
             }}

          :delete ->
            {:ok, %{status: 500}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert {:error, {:github, :http, %{status: 500}}} =
               Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}, 1000
      assert_receive {:github_request, %{method: :delete}}, 1000
      refute_receive {:github_request, %{method: :post}}, 100
      refute_receive {:github_request, %{method: :patch}}, 100
    end
  end
end
