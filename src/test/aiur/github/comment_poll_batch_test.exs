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

  test "batches target issues with per-target headRefName pull request aliases" do
    request_fun = fn %{method: :post, url: url, body: body} ->
      assert url == "https://api.github.com/graphql"
      assert body["query"] =~ "target_0: issueOrPullRequest(number: 42)"
      assert body["query"] =~ ~s(branch_0: pullRequests(headRefName: "aiur/42-comment-batch", states: OPEN)
      refute body["query"] =~ "states: OPEN, after:"
      assert body["variables"] == %{"owner" => "owner", "repo" => "repo"}

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue([comment(1, "issue comment")]),
               "branch_0" => %{
                 "pageInfo" => %{"hasNextPage" => false},
                 "nodes" => [pull_request(77, "aiur/42-comment-batch", [comment(2, "PR comment")])]
               }
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CommentPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"}
             )

    assert [%{"body" => "issue comment"}] = batch.issue_comments
    assert %{"number" => 77, "head" => %{"ref" => "aiur/42-comment-batch"}} = batch.open_pull_request
    assert [%{"body" => "PR comment"}] = batch.pr_issue_comments
    assert batch.review_thread_comments == []
  end

  test "omits an overflowed comment connection so the poller can fetch it completely" do
    request_fun = fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" =>
                 issue([comment(1, "first page")])
                 |> put_in(["comments", "pageInfo"], %{"hasNextPage" => true, "endCursor" => "next"}),
               "branch_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CommentPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"}
             )

    refute Map.has_key?(batch, :issue_comments)
    assert batch.open_pull_request == nil
  end

  test "omits a target whose legacy branch guess finds no PR so REST can resolve it" do
    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ ~s(branch_0: pullRequests(headRefName: "aiur/42", states: OPEN)

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue([comment(1, "issue comment")]),
               "branch_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, batch} = CommentPollBatch.fetch(["42"], request_fun: request_fun)
    refute Map.has_key?(batch, "42")
  end

  test "uses the direct pull request node when the target number is the PR itself" do
    request_fun = fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => pull_request(77, "feature/watched", [comment(3, "watched PR comment")]),
               "branch_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, %{"77" => batch}} = CommentPollBatch.fetch(["77"], request_fun: request_fun)
    assert %{"number" => 77, "head" => %{"ref" => "feature/watched"}} = batch.open_pull_request
    assert [%{"body" => "watched PR comment"}] = batch.pr_issue_comments
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
