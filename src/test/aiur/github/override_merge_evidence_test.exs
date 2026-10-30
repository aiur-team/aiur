defmodule Aiur.GitHub.OverrideMergeEvidenceTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.OverrideMergeEvidence

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "uses the merged PR head commit date rather than the merge time or a later push" do
    at = DateTime.utc_now() |> DateTime.truncate(:second)
    pr = %{head_sha: "merged-head", merged?: true, number: 77}

    request = fn req ->
      assert req.caller == "command_override_merge_head"
      assert req.url == "https://api.github.com/repos/owner/repo/commits/merged-head"
      {:ok, %{status: 200, body: %{"sha" => "merged-head", "commit" => %{"committer" => %{"date" => DateTime.to_iso8601(at)}}}}}
    end

    assert {:ok, result} = OverrideMergeEvidence.read(pr, token: "fixture", request_fun: request)
    assert result.committed_at == at
    assert result.head_sha == "merged-head"
  end

  test "failed, malformed or mismatched head evidence cannot authorize a merge disposition" do
    for result <- [{:error, :unavailable}, {:ok, %{status: 503}}, {:ok, %{status: 200, body: %{"sha" => "later-push"}}}] do
      assert {:error, _} = OverrideMergeEvidence.read(%{head_sha: "merged-head"}, token: "fixture", request_fun: fn _ -> result end)
    end
  end
end
