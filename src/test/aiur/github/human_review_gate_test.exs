defmodule Aiur.GitHub.HumanReviewGateTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{HumanReviewGate, ResourceStore}

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

    # The gate now deposits what it reads. The store is global and long-lived, so
    # one case's deposit would otherwise be visible to the next.
    ResourceStore.reset()
    on_exit(fn -> ResourceStore.reset() end)

    :ok
  end

  describe "verify_human_review_ready/2" do
    test "returns :ok when the canonical aiur/<issue> PR has zero unaddressed thread comments" do
      request_fun = fn req ->
        cond do
          req.method == :get and req.url =~ "/pulls?" ->
            {:ok,
             %{
               status: 200,
               body: [%{"number" => 42, "head" => %{"ref" => "aiur/42", "repo" => %{"full_name" => "owner/repo"}}}]
             }}

          req.method == :post and req.body["query"] =~ "AiurViewerLogin" ->
            {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "aiur-bot"}}}}}

          req.method == :post and req.body["query"] =~ "AiurUnaddressedReviewThreads" ->
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
      end

      assert :ok =
               HumanReviewGate.verify_human_review_ready("99",
                 request_fun: request_fun,
                 bot_account: "aiur-bot"
               )
    end

    test "returns unverified_review_threads error when open PR has unaddressed comments" do
      assert {:error, {:unverified_review_threads, detail}} =
               HumanReviewGate.verify_human_review_ready("42",
                 request_fun: blocking_thread_request_fun([]),
                 bot_account: "aiur-bot"
               )

      assert detail.pr_number == 77
      assert detail.count == 1
      assert "PRRT_blocking" in detail.review_thread_ids
    end

    # #1756: reverting an approved PR to rework deadlocks the ticket — the
    # rework turn has nothing to fix, and its liveness push dismisses the
    # approval that would have released it.
    test "returns :ok when the pull request is approved despite an unaddressed thread" do
      reviews = [
        review("its-everdred", "CHANGES_REQUESTED", "2026-08-08T21:15:00Z"),
        review("its-everdred", "APPROVED", "2026-08-10T10:47:00Z")
      ]

      assert :ok =
               HumanReviewGate.verify_human_review_ready("42",
                 request_fun: blocking_thread_request_fun(reviews),
                 bot_account: "aiur-bot"
               )
    end

    test "still blocks when another reviewer's standing verdict requests changes" do
      reviews = [
        review("its-everdred", "APPROVED", "2026-08-10T10:47:00Z"),
        review("other-owner", "CHANGES_REQUESTED", "2026-08-10T11:00:00Z")
      ]

      assert {:error, {:unverified_review_threads, _detail}} =
               HumanReviewGate.verify_human_review_ready("42",
                 request_fun: blocking_thread_request_fun(reviews),
                 bot_account: "aiur-bot"
               )
    end

    test "fails closed to the block when the reviews read fails" do
      request_fun = fn req ->
        if req.method == :get and req.url =~ "/pulls/77/reviews" do
          {:error, :timeout}
        else
          blocking_thread_request_fun([]).(req)
        end
      end

      assert {:error, {:unverified_review_threads, _detail}} =
               HumanReviewGate.verify_human_review_ready("42",
                 request_fun: request_fun,
                 bot_account: "aiur-bot"
               )
    end

    # R10. This gate is a merge decision, so it declares the strict tolerance and
    # must reach GitHub on every check no matter what the store is holding.
    describe_strict = "the approval read is strict"

    test "#{describe_strict}: it reaches GitHub even with a fresh approval already stored" do
      key = ResourceStore.key_for_repo(:pull_request_reviews, "owner/repo", 77)
      approved = [review("its-everdred", "APPROVED", "2026-08-10T10:47:00Z")]
      # A body deposited a millisecond ago. A cache-satisfied read would answer
      # from this and let the gate pass without asking anybody.
      ResourceStore.put_resource(key, approved, source: :webhook)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      request_fun = fn req ->
        if req.method == :get and req.url =~ "/pulls/77/reviews" do
          Agent.update(counter, &(&1 + 1))
        end

        blocking_thread_request_fun([review("other-owner", "CHANGES_REQUESTED", "2026-08-10T11:00:00Z")]).(req)
      end

      # Upstream says changes are requested, and upstream wins over the stored
      # approval — which is the whole point of a strict read.
      assert {:error, {:unverified_review_threads, _detail}} =
               HumanReviewGate.verify_human_review_ready("42", request_fun: request_fun, bot_account: "aiur-bot")

      assert Agent.get(counter, & &1) == 1
    end

    test "#{describe_strict}: it sends If-None-Match and a 304 answers from the held body" do
      key = ResourceStore.key_for_repo(:pull_request_reviews, "owner/repo", 77)
      approved = [review("its-everdred", "APPROVED", "2026-08-10T10:47:00Z")]
      ResourceStore.put_resource(key, approved, source: :poll, etag: ~s("reviews-v1"))

      {:ok, sent} = Agent.start_link(fn -> [] end)

      request_fun = fn req ->
        if req.method == :get and req.url =~ "/pulls/77/reviews" do
          Agent.update(sent, &(&1 ++ [Map.get(req, :etag)]))
          {:ok, %{status: 304, headers: [{"etag", ~s("reviews-v1")}], body: nil}}
        else
          blocking_thread_request_fun([]).(req)
        end
      end

      # The request happened and carried the stored validator, so it was a fresh
      # answer from GitHub rather than a cached one — and it cost no rate limit.
      assert :ok = HumanReviewGate.verify_human_review_ready("42", request_fun: request_fun, bot_account: "aiur-bot")
      assert Agent.get(sent, & &1) == [~s("reviews-v1")]
    end

    test "#{describe_strict}: it deposits the answer so a tolerant reader rides on the spend" do
      key = ResourceStore.key_for_repo(:pull_request_reviews, "owner/repo", 77)
      approved = [review("its-everdred", "APPROVED", "2026-08-10T10:47:00Z")]

      assert :ok =
               HumanReviewGate.verify_human_review_ready("42",
                 request_fun: blocking_thread_request_fun(approved),
                 bot_account: "aiur-bot"
               )

      assert ResourceStore.data(key) == approved
    end

    test "returns :ok when no open PR exists (FI-GH-033)" do
      request_fun = fn req ->
        cond do
          req.method == :get and req.url =~ "/pulls?" ->
            {:ok, %{status: 200, body: []}}
        end
      end

      assert :ok =
               HumanReviewGate.verify_human_review_ready("99",
                 request_fun: request_fun,
                 bot_account: "aiur-bot"
               )
    end
  end

  # PR 77 with one unresolved thread from a code owner, plus whatever review
  # submissions the caller wants standing on it.
  defp blocking_thread_request_fun(reviews) do
    fn req ->
      cond do
        req.method == :get and req.url =~ "/pulls/77/reviews" ->
          {:ok, %{status: 200, body: reviews}}

        req.method == :get and req.url =~ "/pulls?" ->
          {:ok,
           %{
             status: 200,
             body: [%{"number" => 77, "head" => %{"ref" => "aiur/42", "repo" => %{"full_name" => "owner/repo"}}}]
           }}

        req.method == :post and req.body["query"] =~ "AiurViewerLogin" ->
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "aiur-bot"}}}}}

        req.method == :post and req.body["query"] =~ "AiurUnaddressedReviewThreads" ->
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
                           "id" => "PRRT_blocking",
                           "isResolved" => false,
                           "path" => "src/lib/aiur/github/client.ex",
                           "line" => 5,
                           "comments" => %{
                             "nodes" => [
                               %{
                                 "id" => "PRRC_1",
                                 "databaseId" => 1,
                                 "body" => "please fix this",
                                 "createdAt" => "2026-06-25T04:13:21Z",
                                 "updatedAt" => "2026-06-25T04:13:21Z",
                                 "url" => "https://github.test/discussion_r1",
                                 "author" => %{"login" => "its-everdred"}
                               }
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
    end
  end

  defp review(login, state, submitted_at) do
    %{"id" => :erlang.phash2({login, state, submitted_at}), "user" => %{"login" => login}, "state" => state, "submitted_at" => submitted_at, "body" => ""}
  end
end
