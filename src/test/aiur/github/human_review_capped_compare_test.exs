defmodule Aiur.GitHub.HumanReviewCappedCompareTest do
  # #4533: GitHub caps a comparison's file list at 300 entries. Approved PR
  # contribution checks probe omitted paths by object id instead.
  use Aiur.TestSupport

  alias Aiur.GitHub.{HumanReviewContribution, HumanReviewPathProbe, ResourceStore}

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
end
