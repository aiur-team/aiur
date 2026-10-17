defmodule Aiur.MainWatch.MergeGroupTest do
  use Aiur.TestSupport
  alias Aiur.MainWatch.GitHub

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "merge-group run on landed main SHA is not a main health observation" do
    assert {:ok, %{observations: [], runs: [], merge_groups: []}} = GitHub.poll("main", ["ci"], token: "test-gh-token", request_fun: request(%{}, false, true), actions_write: false)
  end

  test "cancelled newest push falls back to the newest completed push run" do
    assert {:ok, %{observations: [observation], runs: runs}} = GitHub.poll("main", ["ci"], token: "test-gh-token", request_fun: request_with_pushes(), actions_write: false)
    assert observation.sha == "landed"
    assert Enum.map(runs, & &1.id) == [44, 43]
    assert observation.checks == [%{name: "ci gate", conclusion: "success"}]
  end

  test "future guard: wrong queue base or SHA cannot appear in main runs" do
    for override <- [%{"head_sha" => "other"}, %{"head_branch" => "gh-readonly-queue/develop/pr-1-base"}] do
      assert {:ok, %{observations: [], runs: []}} = GitHub.poll("main", ["ci"], token: "test-gh-token", request_fun: request(override, false, false), actions_write: false)
    end
  end

  defp request(override, fail?, no_push?), do: &request_response(&1, override, fail?, no_push?)

  defp request_response(%{url: url}, override, fail?, no_push?) do
    cond do
      String.contains?(url, "/commits?") ->
        ok([%{"sha" => "landed"}])

      String.contains?(url, "/actions/runs?") and String.contains?(url, "event=push") ->
        push_response(override, fail?, no_push?)

      String.contains?(url, "/actions/runs?") ->
        ok(%{"workflow_runs" => [Map.merge(queue_run(), override)]})

      String.contains?(url, "/check-runs?") ->
        ok(%{"check_runs" => [%{"id" => 1, "name" => "ci gate", "status" => "completed", "conclusion" => "success", "check_suite" => %{"id" => 8}, "app" => %{"slug" => "github-actions"}}]})

      String.ends_with?(url, "/status") ->
        ok(%{"statuses" => []})
    end
  end

  defp push_response(_override, _fail?, true), do: ok(%{"workflow_runs" => []})
  defp push_response(_override, true, false), do: ok(%{"workflow_runs" => [push_run(), Map.merge(push_run(), %{"id" => 44, "conclusion" => "cancelled", "updated_at" => "2026-10-12T16:00:00Z"})]})
  defp push_response(override, false, false), do: ok(%{"workflow_runs" => [Map.merge(push_run(), override)]})

  defp request_with_pushes do
    fn %{url: url} ->
      cond do
        String.contains?(url, "/commits?") ->
          ok([%{"sha" => "landed"}])

        String.contains?(url, "/actions/runs?") and String.contains?(url, "event=push") ->
          ok(%{"workflow_runs" => [push_run(), Map.merge(push_run(), %{"id" => 44, "conclusion" => "cancelled", "updated_at" => "2026-10-12T16:00:00Z"})]})

        String.contains?(url, "/actions/runs?") ->
          ok(%{"workflow_runs" => [queue_run() |> Map.merge(%{"conclusion" => "failure"})]})

        String.contains?(url, "/check-runs?") ->
          ok(%{"check_runs" => [%{"id" => 1, "name" => "ci gate", "status" => "completed", "conclusion" => "success", "check_suite" => %{"id" => 8}, "app" => %{"slug" => "github-actions"}}]})

        String.ends_with?(url, "/status") ->
          ok(%{"statuses" => []})
      end
    end
  end

  defp push_run do
    queue_run()
    |> Map.merge(%{"id" => 43, "event" => "push", "head_branch" => "main", "check_suite_id" => 8, "conclusion" => "success", "status" => "completed"})
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
