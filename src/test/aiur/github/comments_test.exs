defmodule Aiur.GitHub.CommentsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Comments

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    :ok
  end

  describe "create_comment/3" do
    test "posts comment body and returns :ok on 201" do
      request_fun = fn %{method: :post, url: url, body: body} ->
        assert url =~ "/issues/7/comments"
        assert body == %{"body" => "Hello"}
        {:ok, %{status: 201}}
      end

      assert :ok = Comments.create_comment("7", "Hello", request_fun: request_fun)
    end

    test "returns error on non-201 status" do
      request_fun = fn _ -> {:ok, %{status: 422, body: %{"message" => "Unprocessable"}}} end
      assert {:error, _} = Comments.create_comment("1", "body", request_fun: request_fun)
    end
  end

  describe "fetch_issue_comments/2" do
    test "returns comments list on 200" do
      comments = [%{"id" => 1, "body" => "first"}, %{"id" => 2, "body" => "second"}]

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/issues/3/comments"
        {:ok, %{status: 200, body: comments, headers: []}}
      end

      assert {:ok, ^comments} = Comments.fetch_issue_comments(3, request_fun: request_fun)
    end
  end

  describe "fetch_recent_repo_review_comments/1" do
    test "returns paginated review comments" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/pulls/comments"
        {:ok, %{status: 200, body: [%{"id" => 99}], headers: []}}
      end

      assert {:ok, [%{"id" => 99}]} =
               Comments.fetch_recent_repo_review_comments(request_fun: request_fun)
    end
  end

  describe "comment_query/1" do
    test "builds query string with defaults" do
      query = Comments.comment_query([])
      assert query =~ "per_page=100"
      assert query =~ "page=1"
    end

    test "accepts per_page and page overrides" do
      query = Comments.comment_query(per_page: 50, page: 2)
      assert query =~ "per_page=50"
      assert query =~ "page=2"
    end
  end
end
