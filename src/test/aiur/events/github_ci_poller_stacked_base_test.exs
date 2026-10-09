defmodule Aiur.Events.GithubCIPollerStackedBaseTest do
  use Aiur.TestSupport
  alias Aiur.Events.{GithubCIPoller, GithubWebhook.Deposit}
  alias Aiur.GitHub.{BoundedBlockedBy, ResourceStore}
  alias Aiur.Workflow

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    old_path = Application.get_env(:aiur, :ci_approval_store_path)
    store_path = Aiur.TestSupport.tmp_root!("stacked_base") <> ".json"
    Application.put_env(:aiur, :ci_approval_store_path, store_path)
    old_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token")

    on_exit(fn ->
      ResourceStore.reset()
      if old_path, do: Application.put_env(:aiur, :ci_approval_store_path, old_path), else: Application.delete_env(:aiur, :ci_approval_store_path)
      if old_token, do: System.put_env("GITHUB_TOKEN", old_token), else: System.delete_env("GITHUB_TOKEN")
      File.rm(store_path)
    end)

    :ok
  end

  test "REST and batched polls preserve an open stack, then repair exactly once after merge" do
    for mode <- [:rest, :batch] do
      ResourceStore.reset()
      blocker_evidence()
      {:ok, base} = Agent.start_link(fn -> "aiur/41-blocker" end)
      {:ok, patches} = Agent.start_link(fn -> [] end)
      request = request_fun(base, patches)

      for _ <- 1..3 do
        assert {:ok, %{errors: [], results: [%{decision: :passed}]}} = poll(mode, base, request)
      end

      assert Agent.get(patches, & &1) == []
      merged_delivery()
      assert {:ok, %{errors: [], results: [%{decision: :failed, base_repair_invalidation: %{repair_state: :repaired}}]}} = poll(mode, base, request)
      assert Agent.get(patches, & &1) == [%{"base" => "main"}]
      assert {:ok, %{errors: [], results: [%{decision: :passed}]}} = poll(mode, base, request)
      assert Agent.get(patches, & &1) == [%{"base" => "main"}]
    end
  end

  test "held direct edges preserve stacks beyond dispatch freshness without blocker issue states" do
    for mode <- [:rest, :batch], issue_evidence <- [:missing, :stale, :closed] do
      ResourceStore.reset()
      blocker_evidence()
      edges_key = ResourceStore.key(:issue_blocked_by, "owner", "repo", "42")
      issue_key = ResourceStore.key(:issue, "owner", "repo", "41")
      ResourceStore.put_resource(edges_key, [%{"number" => 41}])
      age_resource(edges_key)

      case issue_evidence do
        :missing -> ResourceStore.drop_data(issue_key)
        :stale -> age_resource(issue_key)
        :closed -> ResourceStore.put_resource(issue_key, %{"number" => 41, "state" => "closed"})
      end

      {:ok, %{data: [%{"number" => 41}], fetched_at_ms: fetched}} = ResourceStore.fetch(edges_key)
      assert System.system_time(:millisecond) - fetched > BoundedBlockedBy.max_age_ms()
      {:ok, base} = Agent.start_link(fn -> "aiur/41-blocker" end)
      {:ok, patches} = Agent.start_link(fn -> [] end)
      request = request_fun(base, patches)

      for _ <- 1..3 do
        assert {:ok, %{errors: [], results: [%{decision: :passed}]}} = poll(mode, base, request)
      end

      assert Agent.get(patches, & &1) == []
      ResourceStore.put_resource(edges_key, [])
      assert {:ok, %{errors: [], results: [%{decision: :failed}]}} = poll(mode, base, request)
      assert Agent.get(patches, & &1) == [%{"base" => "main"}]
    end
  end

  test "unrelated bases and missing or malformed dependency or PR evidence are repaired" do
    malformed_edges = [%{}, [%{"number" => 41}, nil], [%{"number" => 41}, %{}], [%{"number" => 41}, %{"number" => "41"}], [%{"number" => 41}, %{"number" => 0}]]

    for evidence <- [:unrelated, :no_edges, :no_pr] ++ malformed_edges do
      ResourceStore.reset()
      blocker_evidence()

      case evidence do
        :no_edges -> ResourceStore.drop_data(ResourceStore.key(:issue_blocked_by, "owner", "repo", "42"))
        :no_pr -> ResourceStore.drop_data(ResourceStore.key(:branch_pull_request, "owner", "repo", "41"))
        :unrelated -> :ok
        malformed -> ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", "42"), malformed)
      end

      {:ok, base} = Agent.start_link(fn -> if(evidence == :unrelated, do: "unrelated", else: "aiur/41-blocker") end)
      {:ok, patches} = Agent.start_link(fn -> [] end)
      assert {:ok, %{errors: [], results: [%{decision: :failed}]}} = poll(:batch, base, request_fun(base, patches))
      assert Agent.get(patches, & &1) == [%{"base" => "main"}]
    end
  end

  defp age_resource(key) do
    [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
    aged = System.system_time(:millisecond) - BoundedBlockedBy.max_age_ms() - 1
    :ets.insert(ResourceStore.Table, {key, %{entry | fetched_at_ms: aged, full_body_at_ms: aged}})
  end

  defp blocker_evidence do
    blocker = %{"number" => 41, "state" => "open", "labels" => [], "title" => "Blocker"}
    ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", "42"), [blocker])
    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", "41"), blocker)
    Deposit.deposit("pull_request", %{"action" => "opened", "pull_request" => blocker_pr()}, "owner/repo")
  end

  defp merged_delivery do
    pr = Map.merge(blocker_pr(), %{"state" => "closed", "merged" => true, "merged_at" => "2026-10-09T00:01:00Z", "updated_at" => "2026-10-09T00:01:00Z"})
    Deposit.deposit("pull_request", %{"action" => "closed", "pull_request" => pr}, "owner/repo")
  end

  defp blocker_pr do
    %{"number" => 71, "state" => "open", "merged" => false, "merged_at" => nil, "updated_at" => "2026-10-09T00:00:00Z", "head" => %{"ref" => "aiur/41-blocker", "sha" => "blocker-sha"}}
  end

  defp pr(base), do: %{"number" => 72, "head" => %{"ref" => "aiur/42", "sha" => "dependent-sha", "repo" => %{"full_name" => "owner/repo"}}, "base" => %{"ref" => base}}
  defp checks, do: [%{"name" => "lint", "status" => "completed", "conclusion" => "success"}]
  defp status, do: %{"state" => "success", "statuses" => []}

  defp poll(mode, base, request) do
    opts = [base_branch: "main", request_fun: request, required_check_fetcher: fn _ -> {:ok, []} end]
    batch = %{"42" => %{pull_request: pr(Agent.get(base, & &1)), check_runs: checks(), commit_status: status()}}
    opts = if mode == :batch, do: Keyword.put(opts, :ci_batch, batch), else: opts
    GithubCIPoller.poll(["42"], opts)
  end

  defp replace_base(_base, new_base), do: new_base

  defp request_fun(base, patches) do
    fn request ->
      cond do
        request.method == :patch ->
          Agent.update(patches, &[request.body | &1])
          Agent.update(base, &replace_base(&1, request.body["base"]))
          {:ok, %{status: 200, body: pr(request.body["base"])}}

        String.contains?(request.url, "/pulls?") ->
          {:ok, %{status: 200, body: [pr(Agent.get(base, & &1))]}}

        String.contains?(request.url, "/check-runs?") ->
          {:ok, %{status: 200, body: %{"check_runs" => checks()}}}

        String.ends_with?(request.url, "/status") ->
          {:ok, %{status: 200, body: status()}}

        true ->
          flunk("unexpected request: #{request.method} #{request.url}")
      end
    end
  end
end
