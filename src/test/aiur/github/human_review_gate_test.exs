defmodule Aiur.GitHub.HumanReviewGateTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.GitHub.{Client, HumanReviewGate, ResourceStore}
  alias Aiur.GitHub.ReadCache.Policy
  alias Aiur.Issue

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
          req.method == :get and req.url =~ "/compare/" ->
            {:ok, %{status: 200, body: %{"status" => "ahead"}}}

          req.method == :get and req.url =~ "/pulls?" ->
            {:ok,
             %{
               status: 200,
               body: [%{"number" => 42, "head" => %{"ref" => "aiur/42", "sha" => "tested-head", "repo" => %{"full_name" => "owner/repo"}}}]
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

    test "stale disjoint heads permit the label write for both behind and diverged bases" do
      for status <- ["behind", "diverged"] do
        pr_files = if status == "behind", do: [], else: [%{"filename" => "feature.ex"}]
        request_fun = stale_request_fun(status, pr_files, [%{"filename" => "upstream.ex"}], mergeability(), true)
        assert :ok = Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot", base_branch: "release/next")
        assert_receive :label_written, 1000
      end
    end

    test "a lagging GraphQL baseRefOid does not block a disjoint head against the REST base tip" do
      detail = Map.put(mergeability(), "baseRefOid", "old-base")
      request_fun = stale_request_fun("diverged", [%{"filename" => "feature.ex"}], [%{"filename" => "upstream.ex"}], detail, true)

      assert :ok = Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot", base_branch: "release/next")
      assert_receive :label_written, 1000
    end

    test "UNKNOWN mergeability allows a disjoint head without a conflict signal" do
      detail = Map.put(mergeability(nil), "baseRefOid", "old-base")
      request_fun = stale_request_fun("diverged", [%{"filename" => "feature.ex"}], [%{"filename" => "upstream.ex"}], detail, true)

      assert :ok = Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot", base_branch: "release/next")
      assert_receive :label_written, 1000
    end

    test "overlap refuses labels and returns one actionable worker packet" do
      request_fun = stale_request_fun("diverged", [%{"filename" => "shared.ex"}], [%{"filename" => "shared.ex"}], mergeability())

      executor =
        ToolExecutor.build(%Issue{id: "42", identifier: "42"}, nil, nil, %{},
          coordination_runner: fn _key, operation, _opts -> operation.() end,
          ticket_state_writer: fn id, state ->
            Client.update_issue_state(id, state, request_fun: request_fun, bot_account: "aiur-bot", base_branch: "release/next")
          end
        )

      response = executor.("aiur_set_ticket_state", %{"state" => "human-review"})
      assert response["success"] == false
      error = Jason.decode!(response["output"])["error"]
      assert error["reason"] == "stale_review_base"
      assert error["detail"] == %{"pr_number" => 77, "base_branch" => "release/next", "head_sha" => "tested-head"}
      assert error["message"] =~ "ci-wait"
      refute_receive :label_written, 100
    end

    test "renames overlap through either previous filename and conflicts refuse disjoint heads" do
      cases = [
        {[%{"filename" => "new.ex", "previous_filename" => "old.ex"}], [%{"filename" => "old.ex"}], mergeability()},
        {[%{"filename" => "old.ex"}], [%{"filename" => "new.ex", "previous_filename" => "old.ex"}], mergeability()},
        {[%{"filename" => "feature.ex"}], [%{"filename" => "upstream.ex"}], mergeability(false)}
      ]

      for {pr_files, upstream_files, detail} <- cases do
        request_fun = stale_request_fun("diverged", pr_files, upstream_files, detail)

        assert {:error, {:stale_review_base, %{head_sha: "tested-head"}}} =
                 Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot", base_branch: "release/next")
      end
    end

    test "truncated or malformed file lists and malformed or mismatched mergeability fail closed" do
      valid = [%{"filename" => "feature.ex"}]
      other = [%{"filename" => "upstream.ex"}]
      capped = List.duplicate(%{"filename" => "file.ex"}, 300)

      cases = [
        {nil, other, mergeability()},
        {valid, nil, mergeability()},
        {"invalid", other, mergeability()},
        {valid, "invalid", mergeability()},
        {capped, other, mergeability()},
        {valid, capped, mergeability()},
        {[%{}], other, mergeability()},
        {[%{"filename" => "new.ex", "status" => "renamed"}], other, mergeability()},
        {valid, [%{"filename" => "new.ex", "status" => "renamed", "previous_filename" => nil}], mergeability()},
        {valid, [%{"filename" => ""}], mergeability()},
        {[%{"filename" => "new.ex", "previous_filename" => 42}], other, mergeability()},
        {valid, other, Map.put(mergeability(), "mergeable", nil)},
        {valid, other, Map.put(mergeability(), "mergeable", "invalid")},
        {valid, other, Map.delete(mergeability(), "mergeable")},
        {valid, other, put_in(mergeability(), ["headRefOid"], "new-head")},
        {valid, other, put_in(mergeability(), ["baseRefName"], "other-base")}
      ]

      for {pr_files, upstream_files, detail} <- cases do
        request_fun = stale_request_fun("diverged", pr_files, upstream_files, detail)

        assert {:error, :review_base_ancestry_unavailable} =
                 Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot", base_branch: "release/next")
      end
    end

    test "compatibility checks observe upstream movement after a disjoint handoff" do
      {:ok, snapshots} = Agent.start_link(fn -> [[%{"filename" => "other.ex"}], [%{"filename" => "feature.ex"}]] end)
      fallback = stale_request_fun("diverged", [%{"filename" => "feature.ex"}], [], mergeability(), true)

      request_fun = fn req ->
        if req.url =~ "/compare/tested-head...observed-base" do
          files = Agent.get_and_update(snapshots, fn [files | rest] -> {files, rest} end)
          {:ok, %{status: 200, body: %{"status" => "diverged", "files" => files}}}
        else
          fallback.(req)
        end
      end

      opts = [request_fun: request_fun, bot_account: "aiur-bot", base_branch: "release/next"]
      assert :ok = Client.update_issue_state("42", "human-review", opts)
      assert_receive :label_written, 1000
      assert {:error, {:stale_review_base, %{head_sha: "tested-head"}}} = Client.update_issue_state("42", "human-review", opts)
      refute_receive :label_written, 100
      assert Agent.get(snapshots, & &1) == []
    end

    test "stale compatibility network errors and missing observed base do not permit labels" do
      fallback = stale_request_fun("diverged", [%{"filename" => "feature.ex"}], [%{"filename" => "other.ex"}], mergeability())

      for path <- ["/compare/tested-head...observed-base", "mergeability"] do
        request_fun = fn req ->
          if (mergeability_request?(req) and path == "mergeability") or String.starts_with?(req.url, "https://api.github.com/repos/owner/repo" <> path <> "?") do
            {:error, :timeout}
          else
            fallback.(req)
          end
        end

        assert {:error, {:github, :timeout, %{reason: :timeout}}} =
                 Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot", base_branch: "release/next")
      end

      for body <- [%{"files" => []}, %{"status" => "unknown", "files" => []}] do
        request_fun = fn req ->
          if req.url =~ "/compare/tested-head...observed-base" do
            {:ok, %{status: 200, body: body}}
          else
            fallback.(req)
          end
        end

        assert {:error, :review_base_ancestry_unavailable} =
                 Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot", base_branch: "release/next")
      end

      request_fun = fn req ->
        if req.url =~ "/compare/release%2Fnext...tested-head" do
          {:ok, %{status: 200, body: %{"status" => "diverged", "files" => []}}}
        else
          fallback.(req)
        end
      end

      assert {:error, :review_base_ancestry_unavailable} =
               Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot", base_branch: "release/next")
    end

    test "unavailable ancestry never becomes permission to hand off" do
      fallback = handoff_request_fun([review("its-everdred", "APPROVED", "2026-10-08T00:00:00Z")])

      cases = [
        {{:ok, %{status: 200, body: %{}}}, {:error, :review_base_ancestry_unavailable}},
        {{:ok, %{status: 200, body: %{"status" => "unknown"}}}, {:error, :review_base_ancestry_unavailable}},
        {{:error, :timeout}, {:error, {:github, :timeout, %{reason: :timeout}}}},
        {{:ok, %{status: 403}}, {:error, {:github, :http, %{status: 403}}}}
      ]

      for {result, expected} <- cases do
        request_fun = fn req ->
          if req.method == :get and req.url =~ "/compare/" do
            result
          else
            if req.method in [:post, :delete] and req.url != "https://api.github.com/graphql", do: flunk("unavailable ancestry must not mutate labels")
            fallback.(req)
          end
        end

        assert Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot") == expected
      end

      missing_head = fn req ->
        if req.method == :get and req.url =~ "/pulls?" do
          {:ok, %{status: 200, body: [%{"number" => 77, "head" => %{"ref" => "aiur/42"}}]}}
        else
          if req.method in [:post, :delete] and req.url != "https://api.github.com/graphql", do: flunk("missing head must not mutate labels")
          fallback.(req)
        end
      end

      assert {:error, :review_base_ancestry_unavailable} =
               Client.update_issue_state("42", "human-review", request_fun: missing_head, bot_account: "aiur-bot")
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

  defp mergeability(mergeable? \\ true) do
    %{"headRefOid" => "tested-head", "baseRefName" => "release/next", "baseRefOid" => "observed-base", "mergeable" => mergeable_value(mergeable?)}
  end

  defp mergeable_value(true), do: "MERGEABLE"
  defp mergeable_value(false), do: "CONFLICTING"
  defp mergeable_value(nil), do: "UNKNOWN"

  defp mergeability_request?(%{method: :post, body: %{"query" => query}}), do: String.contains?(query, "AiurHumanReviewMergeability")
  defp mergeability_request?(_req), do: false

  defp stale_request_fun(status, pr_files, upstream_files, detail, allow_labels? \\ false) do
    parent = self()
    fallback = handoff_request_fun([review("its-everdred", "APPROVED", "2026-10-08T00:00:00Z")])

    responses = %{
      "https://api.github.com/repos/owner/repo/compare/release%2Fnext...tested-head?per_page=1" => %{"status" => status, "base_commit" => %{"sha" => "observed-base"}, "files" => pr_files},
      "https://api.github.com/repos/owner/repo/compare/tested-head...observed-base?per_page=1" => %{"status" => "diverged", "files" => upstream_files},
      "https://api.github.com/graphql" => %{"data" => %{"repository" => %{"pullRequest" => detail}}}
    }

    fn req ->
      response = if req.url != "https://api.github.com/graphql" or mergeability_request?(req), do: Map.fetch(responses, req.url), else: :error

      case response do
        {:ok, body} ->
          assert req.caller == "human_review_base_ancestry"
          verify_uncached_mergeability(req)
          {:ok, %{status: 200, body: body}}

        :error ->
          verify_label_write(req, allow_labels?, parent)
          fallback.(req)
      end
    end
  end

  defp verify_uncached_mergeability(req) do
    if mergeability_request?(req) do
      assert {:no_cache, :unsafe_kind} == Policy.classify(req)
      refute req.body["query"] =~ "baseRefOid"
    end
  end

  defp verify_label_write(%{method: method, url: url}, allow?, parent) when method in [:post, :delete] and url != "https://api.github.com/graphql" do
    assert allow?, "unsafe stale head must not mutate labels"
    if method == :post, do: send(parent, :label_written)
  end

  defp verify_label_write(_req, _allow?, _parent), do: :ok

  defp handoff_request_fun(reviews) do
    fallback = blocking_thread_request_fun(reviews)

    fn req ->
      cond do
        req.method == :get and req.url =~ "/issues/42" ->
          {:ok, %{status: 200, body: %{"state" => "open", "labels" => [%{"name" => "agent:in-progress"}]}}}

        req.method in [:post, :delete] and req.url != "https://api.github.com/graphql" ->
          {:ok, %{status: 200}}

        req.method == :get and req.url =~ "/compare/" ->
          {:ok, %{status: 200, body: %{"status" => "ahead"}}}

        true ->
          fallback.(req)
      end
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
             body: [%{"number" => 77, "head" => %{"ref" => "aiur/42", "sha" => "tested-head", "repo" => %{"full_name" => "owner/repo"}}}]
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
