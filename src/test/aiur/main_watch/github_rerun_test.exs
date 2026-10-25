defmodule Aiur.MainWatch.GitHubRerunTest do
  use Aiur.TestSupport
  alias Aiur.MainWatch.GitHub

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "single-test recovery reruns failed jobs and reads complete commit file paths" do
    parent = self()

    request = fn call ->
      send(parent, call)

      if String.ends_with?(call.url, "/commits/sha-123"),
        do: response(200, %{"files" => [%{"filename" => "src/test/one_test.exs"}]}),
        else: response(202, %{})
    end

    assert :ok = GitHub.rerun_failed_jobs(57, token: "test-gh-token", request_fun: request)
    assert_received %{method: :post, url: "https://api.github.com/repos/owner/repo/actions/runs/57/rerun-failed-jobs", caller: "main_watch_single_test_rerun", body: %{}}
    assert {:ok, ["src/test/one_test.exs"]} = GitHub.changed_paths("sha-123", token: "test-gh-token", request_fun: request)
    assert_received %{method: :get, url: "https://api.github.com/repos/owner/repo/commits/sha-123", caller: "main_watch_commit_files"}
  end

  test "single-test recovery rejects incomplete or malformed paths and rerun errors" do
    paginated = fn _ -> response(200, %{"files" => [%{"filename" => "test/a.exs"}]}, [{"link", "<https://api.github.com/next>; rel=\"next\""}]) end
    assert {:error, :main_commit_files_incomplete} = GitHub.changed_paths("sha-123", token: "test-gh-token", request_fun: paginated)

    malformed = fn _ -> response(200, %{"files" => [%{"filename" => "test/a.exs"}, "unexpected"]}) end
    assert {:error, :invalid_main_commit_files} = GitHub.changed_paths("sha-123", token: "test-gh-token", request_fun: malformed)
    assert {:error, {:github, :http, %{status: 403}}} = GitHub.rerun_failed_jobs(57, token: "test-gh-token", request_fun: fn _ -> response(403, %{}) end)
  end

  defp response(status, body, headers \\ []), do: {:ok, %{status: status, body: body, headers: headers}}
end
