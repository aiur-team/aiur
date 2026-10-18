defmodule Aiur.MainWatch.GitHubRecoveryWindowTest do
  use Aiur.TestSupport

  alias Aiur.MainWatch.GitHub

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "red window starts at the first failed workflow run, not an earlier green run" do
    earlier_green = run(13, "red-head", "ci", "success", "2026-10-14T09:00:00Z")
    first_failure = run(14, "red-head", "build", "failure", "2026-10-14T10:00:00Z")
    checks = [check(1, 1, "success"), check(2, 2, "failure")]

    assert {:ok, %{observations: [observation]}} =
             GitHub.poll("main", [], token: "test-gh-token", request_fun: evidence_request([earlier_green, first_failure], checks), actions_write: false)

    assert observation.failed_workflow
    assert observation.started_at == DateTime.to_unix(~U[2026-10-14 10:00:00Z], :millisecond)
  end

  defp evidence_request(runs, checks) do
    fn %{url: url} ->
      request(url, runs, checks)
    end
  end

  defp request(url, runs, checks) do
    routes = [
      {"/commits?", ok([%{"sha" => "red-head"}])},
      {"event=push", ok(%{"workflow_runs" => runs})},
      {"/actions/runs?", ok(%{"workflow_runs" => []})},
      {"/check-runs?", ok(%{"check_runs" => checks})},
      {"/status", ok(%{"statuses" => []})},
      {"/annotations?", ok([])},
      {"/contents/", ok(%{"encoding" => "base64", "content" => ""})},
      {"/issues?", ok([])}
    ]

    Enum.find_value(routes, &route_response(&1, url)) || flunk("unexpected request #{url}")
  end

  defp route_response({path, response}, url), do: if(String.contains?(url, path), do: response)

  defp run(id, sha, workflow, conclusion, created_at) do
    %{
      "id" => id,
      "head_sha" => sha,
      "head_branch" => "main",
      "event" => "push",
      "name" => workflow,
      "status" => "completed",
      "conclusion" => conclusion,
      "check_suite_id" => id - 12,
      "created_at" => created_at,
      "updated_at" => "2026-10-14T11:00:00Z",
      "html_url" => "https://example.test/#{id}"
    }
  end

  defp check(id, suite, conclusion),
    do: %{"id" => id, "name" => "test", "check_suite" => %{"id" => suite}, "app" => %{"slug" => "github-actions"}, "status" => "completed", "conclusion" => conclusion}

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
