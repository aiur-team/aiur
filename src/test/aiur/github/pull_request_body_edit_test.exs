defmodule Aiur.GitHub.PullRequestBodyEditTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.PullRequestBodyEdit

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    :ok
  end

  test "reads the PR body's lastEditedAt, nil when never edited" do
    reply = fn pull_request ->
      fn %{body: %{"variables" => %{"owner" => "owner", "name" => "repo", "number" => 4924}}, caller: "rework_body_edit"} ->
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => pull_request}}}}}
      end
    end

    assert PullRequestBodyEdit.last_edited_at(4924, request_fun: reply.(%{"lastEditedAt" => "2026-10-17T13:55:02Z"})) == {:ok, "2026-10-17T13:55:02Z"}
    assert PullRequestBodyEdit.last_edited_at(4924, request_fun: reply.(%{"lastEditedAt" => nil})) == {:ok, nil}
    assert PullRequestBodyEdit.last_edited_at(4924, request_fun: reply.(nil)) == {:error, :pull_request_body_edit_unreadable}
  end
end
