defmodule Aiur.MainWatch.MergeGroupTest do
  use Aiur.TestSupport
  alias Aiur.MainWatch.GitHub

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "landed main commit is covered by its exact-SHA merge group without a push CI run" do
    assert {:ok, %{observations: [observation], runs: [run]}} = GitHub.poll("main", ["ci"], token: "test-gh-token", request_fun: request(), actions_write: false)
    assert observation.sha == "landed"
    assert observation.checks == [%{name: "ci gate", conclusion: "success"}]
    refute observation.failed_workflow
    assert run.id == 42
    assert run.url == "https://github.com/owner/repo/actions/runs/42"
  end

  test "future guard: wrong queue base or SHA cannot cover main" do
    for override <- [%{"head_sha" => "other"}, %{"head_branch" => "gh-readonly-queue/develop/pr-1-base"}] do
      assert {:ok, %{observations: [], runs: []}} = GitHub.poll("main", ["ci"], token: "test-gh-token", request_fun: request(override), actions_write: false)
    end
  end

  test "unreadable queue census cannot yield partial green from push runs" do
    assert {:error, {:github, :http, %{status: 403}}} = GitHub.poll("main", ["ci"], token: "test-gh-token", request_fun: request(%{}, true), actions_write: false)
  end

  defp request(override \\ %{}, fail? \\ false) do
    fn %{url: url} ->
      cond do
        String.contains?(url, "/commits?") ->
          ok([%{"sha" => "landed"}])

        String.contains?(url, "/actions/runs?") and String.contains?(url, "event=push") ->
          ok(%{"workflow_runs" => []})

        String.contains?(url, "/actions/runs?") and fail? ->
          {:ok, %{status: 403, body: %{}}}

        String.contains?(url, "/actions/runs?") ->
          ok(%{"workflow_runs" => [Map.merge(queue_run(), override)]})

        String.contains?(url, "/check-runs?") ->
          ok(%{"check_runs" => [%{"id" => 1, "name" => "ci gate", "status" => "completed", "conclusion" => "success", "check_suite" => %{"id" => 7}, "app" => %{"slug" => "github-actions"}}]})

        String.ends_with?(url, "/status") ->
          ok(%{"statuses" => []})
      end
    end
  end

  defp queue_run do
    %{
      "id" => 42,
      "head_sha" => "landed",
      "head_branch" => "gh-readonly-queue/main/pr-1-base",
      "event" => "merge_group",
      "name" => "ci",
      "check_suite_id" => 7,
      "status" => "completed",
      "conclusion" => "success",
      "run_attempt" => 1,
      "updated_at" => "2026-10-11T16:00:00Z",
      "html_url" => "https://github.com/owner/repo/actions/runs/42"
    }
  end

  defp ok(body), do: {:ok, %{status: 200, body: body}}
end
