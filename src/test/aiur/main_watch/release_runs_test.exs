defmodule Aiur.MainWatch.ReleaseRunsTest do
  use Aiur.TestSupport
  alias Aiur.MainWatch.GitHub

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "poll returns completed release workflow runs from the base branch" do
    release = %{
      "id" => 12,
      "head_sha" => "release",
      "head_branch" => "main",
      "event" => "workflow_dispatch",
      "name" => "release-npm",
      "status" => "completed",
      "conclusion" => "failure",
      "updated_at" => "2026-11-27T00:00:00Z",
      "html_url" => "release-url"
    }

    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/commits?") -> {:ok, %{status: 200, body: [%{"sha" => "main"}]}}
        String.contains?(url, "/actions/runs?") -> {:ok, %{status: 200, body: %{"workflow_runs" => [release]}}}
        true -> flunk("unexpected request #{url}")
      end
    end

    assert {:ok, %{release_runs: [%{id: 12, name: "release-npm", conclusion: "failure", url: "release-url"}]}} =
             GitHub.poll("main", ["ci"], token: "test-gh-token", request_fun: request, actions_write: false)
  end
end
