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

  describe "fetch_issue_comments_conditional/2" do
    test "sends the saved ETag and treats 304 as a successful unchanged response" do
      request_fun = fn %{method: :get, etag: etag} = request ->
        assert request.url =~ "/issues/3/comments"
        assert etag == ~s("prior-etag")
        {:ok, %{status: 304, headers: [{"etag", ~s("prior-etag")}]}}
      end

      assert {:not_modified, ~s("prior-etag")} =
               Comments.fetch_issue_comments_conditional(3,
                 etag: ~s("prior-etag"),
                 request_fun: request_fun
               )
    end

    test "returns the response ETag with a materialized comments list" do
      request_fun = fn %{method: :get} ->
        {:ok, %{status: 200, body: [%{"id" => 1}], headers: [{"etag", ~s("fresh-etag")}]}}
      end

      assert {:ok, [%{"id" => 1}], ~s("fresh-etag")} =
               Comments.fetch_issue_comments_conditional(3, request_fun: request_fun)
    end

    test "follows all pages after a changed conditional response" do
      request_fun = fn %{method: :get, url: url} ->
        if String.contains?(url, "page=2") do
          {:ok, %{status: 200, body: [%{"id" => 2}], headers: []}}
        else
          next =
            ~s(<https://api.github.com/repos/owner/repo/issues/3/comments?per_page=100&page=2>; rel="next")

          {:ok, %{status: 200, body: [%{"id" => 1}], headers: [{"etag", ~s("fresh-etag")}, {"link", next}]}}
        end
      end

      assert {:ok, [%{"id" => 1}, %{"id" => 2}], ~s("fresh-etag")} =
               Comments.fetch_issue_comments_conditional(3, request_fun: request_fun)
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

  test "conditionally skips an unchanged repo-wide command stream" do
    request_fun = fn %{method: :get, etag: etag, url: url} ->
      assert url =~ "/pulls/comments"
      assert etag == ~s("scan-etag")
      {:ok, %{status: 304, headers: [{"etag", ~s("scan-etag")}]}}
    end

    assert {:not_modified, ~s("scan-etag")} =
             Comments.fetch_recent_repo_review_comments_conditional(etag: ~s("scan-etag"), request_fun: request_fun)
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

    # The poller's cursor. `since` is the only thing that keeps a steady-state
    # comment read from asking for the entire history every cycle, and it is a
    # query parameter — invisible unless the query string itself is asserted.
    # The GraphQL batch used to window on it and no longer fetches comments at
    # all, so this REST query is now the only place the cursor has an effect.
    test "carries the caller's since cursor" do
      assert Comments.comment_query(since: "2026-07-30T12:00:00Z") =~ "since=2026-07-30T12%3A00%3A00Z"
    end

    # Paired with the case above on purpose: an omission assertion alone would
    # pass against a build that had lost the parameter entirely.
    test "omits since when the caller has no cursor" do
      refute Comments.comment_query([]) =~ "since"
      refute Comments.comment_query(since: nil) =~ "since"
    end
  end

  describe "repo_comment_stream_query/1" do
    test "carries the caller's since cursor" do
      assert Comments.repo_comment_stream_query(since: "2026-07-30T12:00:00Z") =~ "since=2026-07-30T12%3A00%3A00Z"
    end

    test "omits since when the caller has no cursor" do
      refute Comments.repo_comment_stream_query([]) =~ "since"
    end
  end

  # End to end rather than on the query builder alone: the cursor is only worth
  # anything if it survives all the way onto the URL the poller actually sends.
  describe "the since cursor reaches GitHub" do
    test "the conditional issue-comment read sends it" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "since=2026-07-30T12%3A00%3A00Z"
        {:ok, %{status: 200, body: [], headers: []}}
      end

      assert {:ok, [], nil} =
               Comments.fetch_issue_comments_conditional(3,
                 since: "2026-07-30T12:00:00Z",
                 request_fun: request_fun
               )
    end

    test "the conditional repo review-comment stream sends it" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "since=2026-07-30T12%3A00%3A00Z"
        {:ok, %{status: 200, body: [], headers: []}}
      end

      assert {:ok, [], nil} =
               Comments.fetch_recent_repo_review_comments_conditional(
                 since: "2026-07-30T12:00:00Z",
                 request_fun: request_fun
               )
    end
  end
end
