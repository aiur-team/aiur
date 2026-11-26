defmodule Aiur.GitHub.OverrideMergeEvidenceTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.OverrideMergeEvidence

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "a recorded worker push equal to the merged head needs no remote read" do
    pr = %{head_sha: "worker", worker_head_sha: "worker", merged?: true, number: 77}
    assert {:ok, result} = OverrideMergeEvidence.read(pr, request_fun: fn _ -> flunk("identical SHAs need no read") end)
    assert result.head_contains_worker_push
    assert result.worker_head_sha == "worker"
  end

  test "a worker push ancestor of the merged head uses one governed immutable comparison" do
    request = fn req ->
      assert req.caller == "command_override_merge_head"
      assert req.url == "https://api.github.com/repos/owner/repo/compare/worker...merged-head?per_page=1"
      {:ok, %{status: 200, body: comparison("ahead", "worker")}}
    end

    assert {:ok, result} = OverrideMergeEvidence.read(%{head_sha: "merged-head", worker_head_sha: "worker"}, token: "fixture", request_fun: request)
    assert result.head_contains_worker_push
    assert result.head_sha == "merged-head"
    assert result.worker_head_sha == "worker"
  end

  test "diverged or older merged heads cannot contain the recorded worker push" do
    for status <- ["behind", "diverged"] do
      request = fn _ -> {:ok, %{status: 200, body: comparison(status, "common-ancestor")}} end
      assert {:ok, result} = OverrideMergeEvidence.read(%{head_sha: "merged-head", worker_head_sha: "worker"}, token: "fixture", request_fun: request)
      refute result.head_contains_worker_push
    end
  end

  test "failed, malformed or mismatched comparisons retain work for retry" do
    for result <- [
          {:error, :unavailable},
          {:ok, %{status: 503}},
          {:ok, %{status: 200, body: %{}}},
          {:ok, %{status: 200, body: %{comparison("ahead", "worker") | "base_commit" => %{"sha" => "other"}}}}
        ] do
      assert {:error, _} = OverrideMergeEvidence.read(%{head_sha: "merged-head", worker_head_sha: "worker"}, token: "fixture", request_fun: fn _ -> result end)
    end

    assert {:error, :merged_head_evidence_missing} = OverrideMergeEvidence.read(%{head_sha: nil, worker_head_sha: "worker"})
  end

  test "a merge without recorded push evidence makes no commit or comparison read" do
    assert {:ok, result} = OverrideMergeEvidence.read(%{head_sha: "update-branch"}, request_fun: fn _ -> flunk("no worker push to prove") end)
    refute result.head_contains_worker_push
  end

  defp comparison(status, ancestor), do: %{"status" => status, "base_commit" => %{"sha" => "worker"}, "merge_base_commit" => %{"sha" => ancestor}}
end
