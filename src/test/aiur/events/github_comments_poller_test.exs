defmodule Aiur.Events.GithubCommentsPollerTest do
  use Aiur.TestSupport
  use Aiur.TestSupport.EventTicket
  import Aiur.TestSupport.CommentsPollerFixture

  alias Aiur.Events.Exchange
  alias Aiur.Events.GithubCommentsPoller

  setup :comments_poller_env

  test "returns default cursor without calling GitHub when there are no targets" do
    assert {:ok, %{count: 0, since: %{}, errors: []}} =
             GithubCommentsPoller.poll(["", "  "], boot_time: 1_782_302_400)
  end

  test "max duration covers the final concurrency wave" do
    assert GithubCommentsPoller.max_duration_ms(13, max_concurrency: 4, timeout: 60_000) == 240_000
  end

  test "normalizes and deduplicates watched targets before polling" do
    ticket = ticket_id()
    fixture_value0 = "/issues/#{ticket}/comments?"
    parent = self()

    request_fun = fn %{url: url} ->
      send(parent, {:requested, url})

      cond do
        String.contains?(url, fixture_value0) -> {:ok, %{status: 200, body: []}}
        String.contains?(url, "/pulls?") -> {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 0, since: %{^ticket => "2026-06-24T11:00:00Z"}, errors: []}} =
             GithubCommentsPoller.poll([ticket, " #{ticket} ", ""],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:requested, issue_comments_url}, 1000
    assert_receive {:requested, pulls_url}, 1000
    refute_receive {:requested, _url}, 100

    assert String.contains?(issue_comments_url, fixture_value0)
    # One listing, not two. The `head=<owner>:aiur/42` probe that used to run in
    # front of this listing could only find branches the listing's own filter
    # already matches, so it was a billed request per target per poll cycle that
    # answered nothing new.
    assert String.contains?(pulls_url, "/pulls?")
    refute String.contains?(pulls_url, "head=")
  end

  test "keeps a per-target issue ETag when comments are unchanged" do
    ticket = ticket_id()
    fixture_value0 = "/issues/#{ticket}/comments?"
    parent = self()

    request_fun = fn request ->
      send(parent, {:requested, request})

      cond do
        String.contains?(request.url, fixture_value0) ->
          assert request.etag == ~s("previous-etag")
          {:ok, %{status: 304, headers: [{"etag", ~s("previous-etag")}]}}

        String.contains?(request.url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok,
            %{
              count: 0,
              errors: [],
              etags: %{^ticket => %{issue: ~s("previous-etag")}}
            }} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               etags: %{ticket => %{issue: ~s("previous-etag")}},
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:requested, %{url: issue_comments_url}}, 1000
    assert String.contains?(issue_comments_url, fixture_value0)
  end

  test "polls issue comments directly and publishes issue.commented" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 1001,
                 "body" => "please rework this",
                 "updated_at" => "2026-06-24T12:00:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1, since: %{^ticket => "2026-06-24T11:59:59Z"}, errors: []}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: ^fixture_topic0,
                      author_trusted?: true,
                      source: :github,
                      message: "please rework this",
                      comment: %{"body" => "please rework this"}
                    }},
                   500

    stop_codeowners(codeowners)
  end

  test "skips Agent Workpad issue comments" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 1002,
                 "body" => "## Agent Workpad\n\n- [x] pushed branch",
                 "updated_at" => "2026-06-24T12:00:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 0, since: %{^ticket => "2026-06-24T11:59:59Z"}, errors: []}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    refute_receive {:event, _}, 100
    stop_codeowners(codeowners)
  end

  test "polls unaddressed PR review threads without requiring a fresh comment timestamp" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
    fixture_value1 = "/issues/#{ticket}/comments?"
    fixture_value2 = "aiur/#{ticket}"
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [%{"number" => 77, "head" => %{"ref" => fixture_value2, "repo" => %{"full_name" => "owner/repo"}}}]
           }}

        String.contains?(url, "/issues/77/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/graphql") ->
          review_threads_response([
            %{
              "id" => "PRRT_old_unresolved",
              "isResolved" => false,
              "path" => "lib/app.ex",
              "line" => 12,
              "comments" => %{
                "nodes" => [
                  review_thread_comment(2102, "its-everdred", "old unresolved thread")
                ]
              }
            }
          ])

        String.contains?(url, "/pulls/77/reviews") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1, since: %{^ticket => "2026-06-25T00:00:00Z"}, errors: []}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-25T00:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: ^fixture_topic0,
                      author_trusted?: true,
                      source: :github,
                      message: "old unresolved thread",
                      comment: %{
                        "body" => "old unresolved thread",
                        "review_thread_id" => "PRRT_old_unresolved"
                      }
                    }},
                   500

    stop_codeowners(codeowners)
  end

  test "polls open PR conversation comments and publishes issue.commented under ticket id" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    fixture_value2 = "aiur/#{ticket}"
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [%{"number" => 77, "head" => %{"ref" => fixture_value2, "repo" => %{"full_name" => "owner/repo"}}}]
           }}

        String.contains?(url, "/issues/77/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 2502,
                 "body" => "conversation needs rework",
                 "updated_at" => "2026-06-24T12:02:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/graphql") ->
          empty_review_threads_response()

        String.contains?(url, "/pulls/77/reviews") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1, since: %{^ticket => "2026-06-24T12:01:59Z"}, errors: []}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: ^fixture_topic0,
                      author_trusted?: true,
                      source: :github,
                      message: "conversation needs rework",
                      comment: %{"body" => "conversation needs rework"}
                    }},
                   500

    stop_codeowners(codeowners)
  end

  test "uses supplied open PR without fetching it again" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    parent = self()
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          send(parent, {:unexpected_pull_request_lookup, url})
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/issues/77/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 2504,
                 "body" => "conversation from supplied pr",
                 "updated_at" => "2026-06-24T12:02:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/graphql") ->
          empty_review_threads_response()

        String.contains?(url, "/pulls/77/reviews") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1, since: %{^ticket => "2026-06-24T12:01:59Z"}, errors: []}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun,
               open_pull_requests_by_target: %{ticket => %{"number" => 77}}
             )

    assert_receive {:event,
                    %{
                      topic: ^fixture_topic0,
                      author_trusted?: true,
                      source: :github,
                      message: "conversation from supplied pr",
                      comment: %{"body" => "conversation from supplied pr"}
                    }},
                   500

    refute_receive {:unexpected_pull_request_lookup, _url}, 100
    stop_codeowners(codeowners)
  end

  test "watched PR keyed by its own number publishes ticket.<pr#>.pr.review_comment via passed PR" do
    parent = self()
    :ok = Exchange.subscribe("ticket.123.pr.review_comment")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        # A watched PR's target IS its PR number, so issue/PR-conversation
        # comments are both fetched against /issues/123/comments.
        String.contains?(url, "/issues/123/comments?") ->
          {:ok, %{status: 200, body: []}}

        # The PR object is supplied, so the poller must NOT branch-derive.
        String.contains?(url, "/pulls?") ->
          send(parent, {:unexpected_pull_request_lookup, url})
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/graphql") ->
          review_threads_response([
            %{
              "id" => "PRRT_watched_pr",
              "isResolved" => false,
              "path" => "lib/app.ex",
              "line" => 9,
              "comments" => %{
                "nodes" => [
                  review_thread_comment(9301, "its-everdred", "watched PR review comment")
                ]
              }
            }
          ])

        String.contains?(url, "/pulls/123/reviews") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1, since: %{"123" => "2026-06-25T00:00:00Z"}, errors: []}} =
             GithubCommentsPoller.poll(["123"],
               since: "2026-06-25T00:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun,
               open_pull_requests_by_target: %{
                 "123" => %{"number" => 123, "head" => %{"ref" => "feature/human-branch"}}
               }
             )

    assert_receive {:event,
                    %{
                      topic: "ticket.123.pr.review_comment",
                      author_trusted?: true,
                      source: :github,
                      message: "watched PR review comment",
                      comment: %{
                        "body" => "watched PR review comment",
                        "review_thread_id" => "PRRT_watched_pr"
                      }
                    }},
                   500

    refute_receive {:unexpected_pull_request_lookup, _url}, 100
    stop_codeowners(codeowners)
  end

  test "skips Agent Workpad PR conversation comments" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    fixture_value2 = "aiur/#{ticket}"
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [%{"number" => 77, "head" => %{"ref" => fixture_value2, "repo" => %{"full_name" => "owner/repo"}}}]
           }}

        String.contains?(url, "/issues/77/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 2503,
                 "body" => "## Agent Workpad\n\n- [x] merged blocker",
                 "updated_at" => "2026-06-24T12:02:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/graphql") ->
          empty_review_threads_response()

        String.contains?(url, "/pulls/77/reviews") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 0, since: %{^ticket => "2026-06-24T12:01:59Z"}, errors: []}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    refute_receive {:event, _}, 100
    stop_codeowners(codeowners)
  end
end
