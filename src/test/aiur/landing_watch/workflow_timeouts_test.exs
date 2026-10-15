defmodule Aiur.LandingWatch.WorkflowTimeoutsTest do
  use Aiur.TestSupport

  alias Aiur.LandingWatch.WorkflowTimeouts

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "maps expanded Actions job names to timeout settings from the run workflow revision" do
    yaml = """
    name: CI
    jobs:
      browser:
        name: browser smoke (3/3)
        timeout-minutes: 15
      lint:
        name: lint
    """

    request = fn request ->
      assert request.url == "https://api.github.com/repos/owner/repo/contents/.github/workflows/ci.yml?ref=merge-sha"
      {:ok, %{status: 200, body: %{"content" => Base.encode64(yaml)}}}
    end

    jobs = [%{"name" => "browser smoke (3/3)"}, %{"name" => "lint"}, %{"name" => "unknown"}]
    run = %{"path" => ".github/workflows/ci.yml", "head_sha" => "merge-sha"}

    assert %{"browser smoke (3/3)" => 15, "lint" => 360} =
             WorkflowTimeouts.for_jobs(run, jobs, token: "test-gh-token", request_fun: request)
  end
end
