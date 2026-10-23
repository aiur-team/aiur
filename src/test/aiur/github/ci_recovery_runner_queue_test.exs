defmodule Aiur.GitHub.CIRecoveryRunnerQueueTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.CIRecovery

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "runner queue restoration reruns the entire cancelled workflow" do
    request = fn req ->
      send(self(), {:runner_rerun, req.method, URI.parse(req.url).path, req.body})
      {:ok, %{status: 201, body: %{}}}
    end

    assert {:ok, %{}} = CIRecovery.rerun_all(987, token: "test-gh-token", request_fun: request)
    assert_received {:runner_rerun, :post, "/repos/owner/repo/actions/runs/987/rerun", %{}}
  end
end
