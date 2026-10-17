defmodule Aiur.GitHub.HumanReviewCappedCompareTest do
  # #4533: GitHub caps a comparison's file list at 300 entries. A capped
  # upstream list must not read as complete, but it must not strand a safe PR
  # either: the PR's own complete path set is probed by object id instead.
  use Aiur.TestSupport

  alias Aiur.GitHub.{Client, HumanReviewContribution, HumanReviewPathProbe, ResourceStore}

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @capped Enum.map(1..300, &%{"filename" => "upstream/#{&1}.ex", "patch" => "@@ -1 +1 @@\n-a\n+b"})

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

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    on_exit(fn -> ResourceStore.reset() end)
    :ok
  end

  describe "stale mergeable head against a capped upstream comparison" do
    test "disjoint PR paths hand off once every path is probed unchanged" do
      request_fun = request_fun("MERGEABLE", %{"f0" => %{"oid" => "blob-a"}, "t0" => %{"oid" => "blob-a"}})

      assert :ok = Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot")
      assert_received {:probe, query}
      assert query =~ ~s("merge-base:feature.ex")
      assert query =~ ~s("observed-base:feature.ex")
      assert_received {:label_written, ["agent:human-review"]}
    end

    test "a PR path changed upstream outside the capped list still refuses handoff" do
      request_fun = request_fun("MERGEABLE", %{"f0" => %{"oid" => "blob-a"}, "t0" => %{"oid" => "blob-b"}})

      assert {:error, {:stale_review_base, %{head_sha: "tested-head"}}} =
               Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot")

      refute_received {:label_written, _labels}
    end

    test "a conflicting PR refuses handoff without probing" do
      request_fun = request_fun("CONFLICTING", %{})

      assert {:error, {:stale_review_base, _detail}} = Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot")
      refute_received {:probe, _query}
      refute_received {:label_written, _labels}
    end

    test "a malformed probe answer fails closed" do
      for objects <- [%{"f0" => %{"oid" => "blob-a"}}, %{"f0" => %{"oid" => ""}, "t0" => nil}] do
        request_fun = request_fun("MERGEABLE", objects)

        assert {:error, :review_base_ancestry_unavailable} =
                 Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot")
      end

      refute_received {:label_written, _labels}
    end
  end

  describe "approved contribution against a capped base comparison" do
    test "an unlisted contribution path proven unchanged keeps the approval" do
      probe = fn paths, from, to ->
        send(self(), {:probed, paths, from, to})
        {:ok, MapSet.new()}
      end

      assert {:ok, true} = unchanged?(probe)
      assert_received {:probed, paths, "old-base", "observed-base"}
      assert paths == MapSet.new(["feature.ex"])
    end

    test "an unlisted contribution path changed upstream fails closed" do
      assert {:error, :review_base_ancestry_unavailable} = unchanged?(fn paths, _from, _to -> {:ok, paths} end)
      assert {:error, :boom} = unchanged?(fn _paths, _from, _to -> {:error, :boom} end)
    end

    test "the real probe reads each contribution path at the merge base and base tip" do
      probe = fn objects ->
        request_fun = fn %{body: %{"query" => query}} ->
          send(self(), {:probe, query})
          {:ok, %{status: 200, body: %{"data" => %{"repository" => objects}}}}
        end

        &HumanReviewPathProbe.changed_paths(&1, &2, &3, %{request_fun: request_fun, token: "test-gh-token"})
      end

      assert {:ok, true} = unchanged?(probe.(%{"f0" => %{"oid" => "blob-a"}, "t0" => %{"oid" => "blob-a"}}))
      assert_received {:probe, query}
      assert query =~ ~s("old-base:feature.ex")
      assert query =~ ~s("observed-base:feature.ex")

      assert {:error, :review_base_ancestry_unavailable} = unchanged?(probe.(%{"f0" => %{"oid" => "blob-a"}, "t0" => %{"oid" => "blob-b"}}))
      assert {:error, :review_base_ancestry_unavailable} = unchanged?(probe.(%{"f0" => %{"oid" => "blob-a"}}))
    end
  end

  defp unchanged?(probe) do
    patch = "@@ -1,3 +1,3 @@\n before\n-old feature\n+new feature\n after"
    feature = %{"files" => [%{"filename" => "feature.ex", "patch" => patch}]}
    merge = %{"sha" => "merge-sha", "parents" => [%{"sha" => "approved-head"}, %{"sha" => "observed-base"}]}

    responses = %{
      {"observed-base", "approved-head"} => %{"merge_base_commit" => %{"sha" => "old-base"}},
      {"old-base", "observed-base"} => %{"total_commits" => 1, "commits" => [%{"sha" => "main-commit"}], "files" => @capped},
      {"approved-head", "tested-head"} => %{"total_commits" => 1, "commits" => [merge]},
      {"old-base", "approved-head"} => feature
    }

    compare = fn base, head, 100 -> Map.fetch(responses, {base, head}) end
    HumanReviewContribution.unchanged?("approved-head", "tested-head", "observed-base", feature, compare, probe)
  end

  # PR 77 has no approval, so a mergeable stale head takes the disjoint-path route.
  defp request_fun(mergeable, probe_objects) do
    parent = self()
    detail = %{"headRefOid" => "tested-head", "baseRefName" => "main", "mergeable" => mergeable, "reviewDecision" => nil, "reviews" => %{"nodes" => []}}
    threads = %{"reviewThreads" => %{"pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}, "nodes" => []}}

    # First match wins, on the URL or the GraphQL query name.
    routes = [
      {"/compare/main...tested-head", %{"status" => "diverged", "base_commit" => %{"sha" => "observed-base"}, "files" => [%{"filename" => "feature.ex"}]}},
      {"/compare/tested-head...observed-base", %{"status" => "diverged", "merge_base_commit" => %{"sha" => "merge-base"}, "files" => @capped}},
      {"AiurHumanReviewPathBlobs", %{"data" => %{"repository" => probe_objects}}},
      {"AiurHumanReviewMergeability", %{"data" => %{"repository" => %{"pullRequest" => detail}}}},
      {"AiurViewerLogin", %{"data" => %{"viewer" => %{"login" => "aiur-bot"}}}},
      {"AiurUnaddressedReviewThreads", %{"data" => %{"repository" => %{"pullRequest" => threads}}}},
      {"/pulls/77/reviews", []},
      {"/pulls?", [%{"number" => 77, "head" => %{"ref" => "aiur/42", "sha" => "tested-head", "repo" => %{"full_name" => "owner/repo"}}}]},
      {"/issues/42/labels", []},
      {"/issues/42", %{"state" => "open", "labels" => [%{"name" => "agent:in-progress"}]}}
    ]

    fn req ->
      body = Map.get(req, :body) || %{}
      query = to_string(body["query"])
      if req.method == :post and is_list(body["labels"]), do: send(parent, {:label_written, body["labels"]})
      if query =~ "AiurHumanReviewPathBlobs", do: send(parent, {:probe, query})

      {_route, response} = Enum.find(routes, fn {route, _response} -> req.url <> " " <> query =~ route end)
      {:ok, %{status: 200, body: response}}
    end
  end
end
