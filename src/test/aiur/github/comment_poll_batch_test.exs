defmodule Aiur.GitHub.CommentPollBatchTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.CommentPollBatch

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    :ok
  end

  test "batches target issues with matching readable ticket pull requests" do
    request_fun = fn %{method: :post, url: url, body: body} ->
      assert url == "https://api.github.com/graphql"
      assert body["query"] =~ "target_42: issueOrPullRequest(number: 42)"
      assert body["variables"] == %{"owner" => "owner", "repo" => "repo", "cursor" => nil}

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_42" => issue([comment(1, "issue comment")]),
               "pullRequests" => %{
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                 "nodes" => [pull_request(77, "aiur/42-comment-batch", [comment(2, "PR comment")])]
               }
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} = CommentPollBatch.fetch(["42"], request_fun: request_fun)
    assert [%{"body" => "issue comment"}] = batch.issue_comments
    assert %{"number" => 77, "head" => %{"ref" => "aiur/42-comment-batch"}} = batch.open_pull_request
    assert [%{"body" => "PR comment"}] = batch.pr_issue_comments
    assert batch.review_thread_comments == []
  end

  defp issue(comments), do: %{"comments" => %{"nodes" => comments}}

  defp pull_request(number, branch, comments) do
    %{
      "number" => number,
      "state" => "OPEN",
      "headRefName" => branch,
      "headRefOid" => "head-#{number}",
      "baseRefName" => "develop",
      "comments" => %{"nodes" => comments},
      "reviewThreads" => %{"nodes" => []}
    }
  end

  defp comment(id, body) do
    %{
      "databaseId" => id,
      "body" => body,
      "createdAt" => "2026-07-30T12:00:00Z",
      "updatedAt" => "2026-07-30T12:00:00Z",
      "url" => "https://example.test/comments/#{id}",
      "author" => %{"login" => "its-everdred"}
    }
  end
end
