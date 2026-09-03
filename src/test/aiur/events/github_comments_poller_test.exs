defmodule Aiur.Events.GithubCommentsPollerTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubCommentsPoller, Publisher}
  alias Aiur.GitHub.{CodeOwners, ResourceStore}
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      Publisher.set_tracked_fn(fn _ -> true end)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end

      # This suite publishes reviews and comments through the shared
      # `Publisher`, which marks them in `ResourceStore` and records their
      # dedup keys in the volatile `Publisher.Dedup` window. Neither is cleared
      # per test anywhere else, so a sibling suite that publishes the same
      # review ids (e.g. `WebhookPollReconciliationTest`) would be silently
      # suppressed by the leaked marks/keys when this suite runs first. Clean
      # both up so the shared state is self-contained per module.
      ResourceStore.reset()

      case :ets.whereis(Aiur.Events.Publisher.Dedup) do
        :undefined -> :ok
        table -> :ets.delete_all_objects(table)
      end
    end)

    :ok
  end

  test "returns default cursor without calling GitHub when there are no targets" do
    assert {:ok, %{count: 0, since: %{}, errors: []}} =
             GithubCommentsPoller.poll(["", "  "], boot_time: 1_782_302_400)
  end

  test "max duration covers the final concurrency wave" do
    assert GithubCommentsPoller.max_duration_ms(13, max_concurrency: 4, timeout: 60_000) == 240_000
  end

  test "normalizes and deduplicates watched targets before polling" do
    parent = self()

    request_fun = fn %{url: url} ->
      send(parent, {:requested, url})

      cond do
        String.contains?(url, "/issues/42/comments?") -> {:ok, %{status: 200, body: []}}
        String.contains?(url, "/pulls?") -> {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 0, since: %{"42" => "2026-06-24T11:00:00Z"}, errors: []}} =
             GithubCommentsPoller.poll(["42", " 42 ", ""],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:requested, issue_comments_url}
    assert_receive {:requested, pulls_url}
    refute_receive {:requested, _url}, 100

    assert String.contains?(issue_comments_url, "/issues/42/comments?")
    # One listing, not two. The `head=<owner>:aiur/42` probe that used to run in
    # front of this listing could only find branches the listing's own filter
    # already matches, so it was a billed request per target per poll cycle that
    # answered nothing new.
    assert String.contains?(pulls_url, "/pulls?")
    refute String.contains?(pulls_url, "head=")
  end

  test "keeps a per-target issue ETag when comments are unchanged" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:requested, request})

      cond do
        String.contains?(request.url, "/issues/42/comments?") ->
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
              etags: %{"42" => %{issue: ~s("previous-etag")}}
            }} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               etags: %{"42" => %{issue: ~s("previous-etag")}},
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:requested, %{url: issue_comments_url}}
    assert String.contains?(issue_comments_url, "/issues/42/comments?")
  end

  test "polls issue comments directly and publishes issue.commented" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
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

    assert {:ok, %{count: 1, since: %{"42" => "2026-06-24T11:59:59Z"}, errors: []}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: "ticket.42.issue.commented",
                      author_trusted?: true,
                      source: :github,
                      message: "please rework this",
                      comment: %{"body" => "please rework this"}
                    }},
                   500

    stop_codeowners(codeowners)
  end

  test "skips Agent Workpad issue comments" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
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

    assert {:ok, %{count: 0, since: %{"42" => "2026-06-24T11:59:59Z"}, errors: []}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    refute_receive {:event, _}, 100
    stop_codeowners(codeowners)
  end

  test "polls unaddressed PR review threads without requiring a fresh comment timestamp" do
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [%{"number" => 77, "head" => %{"ref" => "aiur/42", "repo" => %{"full_name" => "owner/repo"}}}]
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

    assert {:ok, %{count: 1, since: %{"42" => "2026-06-25T00:00:00Z"}, errors: []}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-25T00:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: "ticket.42.pr.review_comment",
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
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [%{"number" => 77, "head" => %{"ref" => "aiur/42", "repo" => %{"full_name" => "owner/repo"}}}]
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

    assert {:ok, %{count: 1, since: %{"42" => "2026-06-24T12:01:59Z"}, errors: []}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: "ticket.42.issue.commented",
                      author_trusted?: true,
                      source: :github,
                      message: "conversation needs rework",
                      comment: %{"body" => "conversation needs rework"}
                    }},
                   500

    stop_codeowners(codeowners)
  end

  test "uses supplied open PR without fetching it again" do
    parent = self()
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
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

    assert {:ok, %{count: 1, since: %{"42" => "2026-06-24T12:01:59Z"}, errors: []}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun,
               open_pull_requests_by_target: %{"42" => %{"number" => 77}}
             )

    assert_receive {:event,
                    %{
                      topic: "ticket.42.issue.commented",
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
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [%{"number" => 77, "head" => %{"ref" => "aiur/42", "repo" => %{"full_name" => "owner/repo"}}}]
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

    assert {:ok, %{count: 0, since: %{"42" => "2026-06-24T12:01:59Z"}, errors: []}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    refute_receive {:event, _}, 100
    stop_codeowners(codeowners)
  end

  test "trusts configured accounts when CODEOWNERS does not include the commenter" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")

    configure_github(trusted_accounts: ["its-everdred"])
    codeowners = ensure_configured_codeowners!("* @someone-else\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 2602,
                 "body" => "trusted by config",
                 "updated_at" => "2026-06-24T12:03:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1, since: %{"42" => "2026-06-24T12:02:59Z"}, errors: []}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: "ticket.42.issue.commented",
                      author_trusted?: true,
                      source: :github,
                      message: "trusted by config",
                      comment: %{"body" => "trusted by config"}
                    }},
                   500

    stop_codeowners(codeowners)
  end

  test "dedupes comments already published by another source" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 3003,
                 "body" => "same comment",
                 "updated_at" => "2026-06-24T12:02:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500

    assert {:ok, %{count: 0}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    refute_receive {:event, _}, 100
    stop_codeowners(codeowners)
  end

  test "keeps cursor unchanged when published comments have no valid timestamp" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 5005,
                 "body" => "timestamp should not advance",
                 "updated_at" => "not-a-date",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1, since: %{"42" => "2026-06-24T11:00:00Z"}, errors: []}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500
    stop_codeowners(codeowners)
  end

  test "ignores open PR results without a usable PR number" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") -> {:ok, %{status: 200, body: []}}
        String.contains?(url, "/pulls?") -> {:ok, %{status: 200, body: [%{}]}}
      end
    end

    assert {:ok, %{count: 0, since: %{"42" => "2026-06-24T11:00:00Z"}, errors: []}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )
  end

  test "advances successful target cursor when another target fails" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 4204,
                 "body" => "target A still moves",
                 "updated_at" => "2026-06-24T12:04:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        # Both targets read the same open-pull-request listing URL now that the
        # per-target `head=<owner>:aiur/<n>` probe is gone — it could only find
        # branches the listing's own filter already matches, so it was a billed
        # request per target per cycle that answered nothing new. The failing
        # target is therefore made to fail on a request that is still its own:
        # its issue-comment read.
        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/issues/43/comments?") ->
          {:error, :timeout}
      end
    end

    assert {:ok,
            %{
              count: 1,
              since: %{
                "42" => "2026-06-24T12:03:59Z",
                "43" => "2026-06-24T11:00:00Z"
              },
              errors: [{"43", {:issue_comments, {:github, :timeout, %{reason: :timeout}}}}]
            }} =
             GithubCommentsPoller.poll(["42", "43"],
               since: %{"42" => "2026-06-24T11:00:00Z", "43" => "2026-06-24T11:00:00Z"},
               repo: "owner/repo",
               request_fun: request_fun,
               max_concurrency: 2
             )

    assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500
    stop_codeowners(codeowners)
  end

  test "keeps successful target isolated when another target task crashes" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 4205,
                 "body" => "target A still publishes",
                 "updated_at" => "2026-06-24T12:05:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/issues/43/comments?") ->
          raise "target 43 crash"
      end
    end

    assert {:ok,
            %{
              count: 1,
              since: %{
                "42" => "2026-06-24T12:04:59Z",
                "43" => "2026-06-24T11:00:00Z"
              },
              errors: errors
            }} =
             GithubCommentsPoller.poll(["42", "43"],
               since: %{"42" => "2026-06-24T11:00:00Z", "43" => "2026-06-24T11:00:00Z"},
               repo: "owner/repo",
               request_fun: request_fun,
               max_concurrency: 2
             )

    assert [{"43", {:target, {:exit, {%RuntimeError{message: "target 43 crash"}, [_ | _]}}}}] =
             errors

    assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500
    stop_codeowners(codeowners)
  end

  test "reports timed out target task as target-local error" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/issues/43/comments?") ->
          Process.sleep(:infinity)
      end
    end

    assert {:ok,
            %{
              count: 0,
              since: %{
                "42" => "2026-06-24T11:00:00Z",
                "43" => "2026-06-24T11:00:00Z"
              },
              errors: [{"43", {:target, {:exit, :timeout}}}]
            }} =
             GithubCommentsPoller.poll(["42", "43"],
               since: %{"42" => "2026-06-24T11:00:00Z", "43" => "2026-06-24T11:00:00Z"},
               repo: "owner/repo",
               request_fun: request_fun,
               max_concurrency: 2,
               timeout: 1_000
             )
  end

  test "reports an error and leaves target cursor unchanged when any watched endpoint fails" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 4004,
                 "body" => "issue comment still publishes",
                 "updated_at" => "2026-06-24T12:03:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:error, :timeout}
      end
    end

    assert {:ok,
            %{
              count: 1,
              since: %{"42" => "2026-06-24T11:00:00Z"},
              errors: [{"42", {:pr_lookup, {:github, :timeout, %{reason: :timeout}}}}]
            }} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500
    stop_codeowners(codeowners)
  end

  test "reports an error when issue comment polling fails" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") -> {:error, :timeout}
        String.contains?(url, "/pulls?") -> {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok,
            %{
              count: 0,
              since: %{"42" => "2026-06-24T11:00:00Z"},
              errors: [{"42", {:issue_comments, {:github, :timeout, %{reason: :timeout}}}}]
            }} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )
  end

  describe "PR review submission polling" do
    test "publishes pr.review_comment for CHANGES_REQUESTED from a trusted reviewer" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_001, "its-everdred", "CHANGES_REQUESTED", "please rework this section")

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event,
                      %{
                        topic: "ticket.42.pr.review_comment",
                        author_trusted?: true,
                        source: :github,
                        comment: %{
                          "state" => "CHANGES_REQUESTED",
                          "body" => "please rework this section"
                        }
                      }},
                     500

      stop_codeowners(codeowners)
    end

    # #1756: the orchestrator's rework gate is a pure function over the event,
    # so the review decision and head commit date the batch resolved have to
    # ride along on every published PR comment and review event.
    test "carries the pull request review context onto published review events" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_010, "its-everdred", "CHANGES_REQUESTED", "please rework this section")

      batch = %{
        "42" => %{
          open_pull_request: %{
            "number" => 77,
            "review_decision" => "CHANGES_REQUESTED",
            "head_committed_at" => "2026-08-10T04:29:00Z"
          },
          issue_comments: [],
          pr_issue_comments: [],
          review_thread_comments: []
        }
      }

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 comment_batch: batch,
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event,
                      %{
                        topic: "ticket.42.pr.review_comment",
                        pull_request: %{
                          "review_decision" => "CHANGES_REQUESTED",
                          "head_committed_at" => "2026-08-10T04:29:00Z"
                        }
                      }},
                     500

      stop_codeowners(codeowners)
    end

    test "publishes pr.review_comment for COMMENTED from a trusted reviewer" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_002, "its-everdred", "COMMENTED", "left some thoughts in review body")

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event,
                      %{
                        topic: "ticket.42.pr.review_comment",
                        author_trusted?: true,
                        source: :github,
                        comment: %{"state" => "COMMENTED"}
                      }},
                     500

      stop_codeowners(codeowners)
    end

    test "publishes pr.review_comment with author_trusted? false for untrusted reviewer" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_003, "outsider", "CHANGES_REQUESTED", "some feedback")

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event,
                      %{
                        topic: "ticket.42.pr.review_comment",
                        author_trusted?: false
                      }},
                     500

      stop_codeowners(codeowners)
    end

    test "does not publish pr.review_comment for APPROVED review" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_004, "its-everdred", "APPROVED", "lgtm")

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 100
      stop_codeowners(codeowners)
    end

    test "does not publish pr.review_comment for DISMISSED review" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_005, "its-everdred", "DISMISSED", "")

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 100
      stop_codeowners(codeowners)
    end

    test "publishes only the most recent review per reviewer when multiple exist" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      older = pr_review(9_006, "its-everdred", "COMMENTED", "first pass", "2026-06-24T10:00:00Z")

      newer =
        pr_review(
          9_007,
          "its-everdred",
          "CHANGES_REQUESTED",
          "second pass",
          "2026-06-24T12:00:00Z"
        )

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([older, newer])
               )

      assert_receive {:event,
                      %{
                        topic: "ticket.42.pr.review_comment",
                        comment: %{"id" => 9_007, "state" => "CHANGES_REQUESTED"}
                      }},
                     500

      refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 100
      stop_codeowners(codeowners)
    end

    test "does not publish pr.review_comment when reviewer's latest is APPROVED after CHANGES_REQUESTED" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      older =
        pr_review(
          9_010,
          "its-everdred",
          "CHANGES_REQUESTED",
          "please fix",
          "2026-06-24T10:00:00Z"
        )

      newer =
        pr_review(9_011, "its-everdred", "APPROVED", "lgtm after fixes", "2026-06-24T14:00:00Z")

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([older, newer])
               )

      refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 100
      stop_codeowners(codeowners)
    end

    test "a later blank-bodied COMMENTED container does not mask an earlier CHANGES_REQUESTED" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      changes_requested =
        pr_review(
          9_012,
          "its-everdred",
          "CHANGES_REQUESTED",
          "please fix",
          "2026-06-24T12:00:00Z"
        )

      # GitHub wraps a later inline-only comment in an empty-bodied COMMENTED
      # review. It must be transparent, not the reviewer's "most recent".
      inline_container = pr_review(9_013, "its-everdred", "COMMENTED", "", "2026-06-24T13:00:00Z")

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([changes_requested, inline_container])
               )

      assert_receive {:event,
                      %{
                        topic: "ticket.42.pr.review_comment",
                        comment: %{"id" => 9_012, "state" => "CHANGES_REQUESTED"}
                      }},
                     500

      refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 100
      stop_codeowners(codeowners)
    end

    test "publishes one review per reviewer when multiple trusted reviewers" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred @other-reviewer\n")

      review_a = pr_review(9_008, "its-everdred", "CHANGES_REQUESTED", "feedback from A")
      review_b = pr_review(9_009, "other-reviewer", "CHANGES_REQUESTED", "feedback from B")

      assert {:ok, %{count: 2, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review_a, review_b])
               )

      assert_receive {:event, %{topic: "ticket.42.pr.review_comment", comment: %{"id" => 9_008}}},
                     500

      assert_receive {:event, %{topic: "ticket.42.pr.review_comment", comment: %{"id" => 9_009}}},
                     500

      stop_codeowners(codeowners)
    end

    test "deduplicates PR review submissions on repeated polls" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_020, "its-everdred", "CHANGES_REQUESTED", "please rework")

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event, %{topic: "ticket.42.pr.review_comment", comment: %{"id" => 9_020}}},
                     500

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 100
      stop_codeowners(codeowners)
    end

    test "reports an error and zero count when PR reviews fetch fails" do
      codeowners = ensure_codeowners!("* @its-everdred\n")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/42/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [%{"number" => 77, "head" => %{"ref" => "aiur/42", "repo" => %{"full_name" => "owner/repo"}}}]
             }}

          String.contains?(url, "/issues/77/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()

          String.contains?(url, "/pulls/77/reviews") ->
            {:error, :timeout}
        end
      end

      assert {:ok, %{count: 0, errors: [{"42", {:pr_reviews, _}}]}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun
               )

      stop_codeowners(codeowners)
    end

    test "a transient PR reviews failure does not stall the issue-comment watermark" do
      # Regression for #1389 P0: if /reviews 403s, the issue-comment since must
      # still advance. Previously errors == [] gated advance_since unconditionally.
      :ok = Exchange.subscribe("ticket.42.issue.commented")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/42/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 99_001,
                   "body" => "looks good to me",
                   "updated_at" => "2026-06-24T12:00:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [%{"number" => 77, "head" => %{"ref" => "aiur/42", "repo" => %{"full_name" => "owner/repo"}}}]
             }}

          String.contains?(url, "/issues/77/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()

          String.contains?(url, "/pulls/77/reviews") ->
            {:error, :timeout}
        end
      end

      assert {:ok, %{since: %{"42" => since}, errors: [{"42", {:pr_reviews, _}}]}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun
               )

      assert since > "2026-06-24T11:00:00Z", "since must advance past the new comment even when /reviews fails"
      assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500
      stop_codeowners(codeowners)
    end

    test "blank-bodied COMMENTED reviews are not published (avoid double-wake for inline-only reviews)" do
      # GitHub creates an empty COMMENTED review as the container for inline
      # comments. Those inline comments are already published via review threads;
      # publishing the blank container too would double-wake the agent.
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      blank_commented = pr_review(9_030, "its-everdred", "COMMENTED", "")

      request_fun = request_fun_with_reviews([blank_commented])

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun
               )

      refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 100
      stop_codeowners(codeowners)
    end

    test "COMMENTED review with a body is published" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      commented_with_body = pr_review(9_032, "its-everdred", "COMMENTED", "minor nit: fix the spacing")

      request_fun = request_fun_with_reviews([commented_with_body])

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun
               )

      assert_receive {:event, %{topic: "ticket.42.pr.review_comment", comment: %{"id" => 9_032}}}, 500
      stop_codeowners(codeowners)
    end
  end

  # #1680 criterion 6: #1427's review poller has to keep working as the fallback
  # path for review submissions. `poll_pr_review_submissions/5` picks its cutoff
  # as `pr_review_seen_at || current_target_since || boot cutoff`, so a review is
  # recovered exactly when a cursor predating it reaches this opt.
  #
  # These pin both halves of that rule, including the half the operator
  # explicitly accepted on 2026-08-10: cursors do not survive a restart, so a
  # review submitted while the daemon was down is dropped rather than recovered.
  # That is the accepted cost of dropping gap detection, and the second test
  # exists so the behavior is pinned rather than assumed.
  #
  # The daemon is down 17:00 -> 18:00 and the review lands at 17:30. The two
  # tests differ only in whether a cursor was supplied, so the recovery
  # assertion cannot pass for an unrelated reason.
  describe "PR review submissions across a daemon outage" do
    @outage_boot_time DateTime.to_unix(~U[2026-07-12 18:00:00Z])
    @review_during_outage "2026-07-12T17:30:00Z"
    @cursor_before_outage "2026-07-12T17:00:00Z"

    test "recovers a review submitted while the daemon was down from a cursor predating it" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_101, "its-everdred", "CHANGES_REQUESTED", "reviewed during the outage", @review_during_outage)

      assert {:ok, %{count: 1, errors: [], pr_review_seen_at: seen_at}} =
               GithubCommentsPoller.poll(["42"],
                 repo: "owner/repo",
                 boot_time: @outage_boot_time,
                 pr_review_seen_at: %{"42" => @cursor_before_outage},
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event,
                      %{
                        topic: "ticket.42.pr.review_comment",
                        author_trusted?: true,
                        comment: %{"id" => 9_101, "state" => "CHANGES_REQUESTED"}
                      }},
                     500

      # The cursor advances past the recovered review, so the next sweep does
      # not republish it.
      assert seen_at == %{"42" => @review_during_outage}

      stop_codeowners(codeowners)
    end

    test "drops the same review when no cursor survived the restart" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_102, "its-everdred", "CHANGES_REQUESTED", "reviewed during the outage", @review_during_outage)

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll(["42"],
                 repo: "owner/repo",
                 boot_time: @outage_boot_time,
                 request_fun: request_fun_with_reviews([review])
               )

      refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 200

      stop_codeowners(codeowners)
    end
  end

  defp ensure_codeowners!(contents) do
    case Process.whereis(CodeOwners) do
      pid when is_pid(pid) ->
        previous_allowlist = CodeOwners.snapshot(pid)
        :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(["its-everdred"])})

        %{pid: pid, path: nil, owned?: false, previous_allowlist: previous_allowlist}

      nil ->
        path =
          Aiur.TestSupport.tmp_root!("aiur-codeowners")

        File.write!(path, contents)

        {:ok, pid} = CodeOwners.start_link(path: path, refresh_seconds: 3600)

        %{pid: pid, path: path, owned?: true}
    end
  end

  defp ensure_configured_codeowners!(contents) do
    path = Aiur.TestSupport.tmp_root!("aiur-codeowners")
    File.write!(path, contents)

    case Process.whereis(CodeOwners) do
      pid when is_pid(pid) ->
        previous_state = :sys.get_state(pid)

        :sys.replace_state(pid, fn state ->
          %{state | allowlist: MapSet.new(["__codeowners_bootstrap__"]), codeowners_path: path}
        end)

        :ok = CodeOwners.refresh(pid)

        %{pid: pid, path: path, owned?: false, previous_state: previous_state}

      nil ->
        {:ok, pid} = CodeOwners.start_link(path: path, refresh_seconds: 3600)
        %{pid: pid, path: path, owned?: true}
    end
  end

  defp configure_github(opts) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_bot_account: Keyword.get(opts, :bot_account),
      tracker_trusted_accounts: Keyword.get(opts, :trusted_accounts, [])
    )
  end

  defp stop_codeowners(%{pid: pid, owned?: false, previous_allowlist: previous_allowlist}) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(previous_allowlist)})
    end
  end

  defp stop_codeowners(%{pid: pid, path: path, owned?: false, previous_state: previous_state}) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, fn _state -> previous_state end)
    end

    File.rm(path)
  end

  defp stop_codeowners(%{pid: pid, path: path, owned?: true}) do
    Aiur.TestSupport.safe_stop(pid)
    File.rm(path)
  end

  defp empty_review_threads_response, do: review_threads_response([])

  defp review_threads_response(nodes) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "reviewThreads" => %{
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                 "nodes" => nodes
               }
             }
           }
         }
       }
     }}
  end

  defp review_thread_comment(id, login, body) do
    %{
      "databaseId" => id,
      "body" => body,
      "createdAt" => "2026-06-24T10:00:00Z",
      "updatedAt" => "2026-06-24T10:00:00Z",
      "url" => "https://github.test/discussion_r#{id}",
      "author" => %{"login" => login}
    }
  end

  defp pr_review(id, login, state, body, submitted_at \\ "2026-06-24T12:00:00Z") do
    %{
      "id" => id,
      "state" => state,
      "body" => body,
      "submitted_at" => submitted_at,
      "user" => %{"login" => login}
    }
  end

  defp request_fun_with_reviews(reviews) do
    fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [%{"number" => 77, "head" => %{"ref" => "aiur/42", "repo" => %{"full_name" => "owner/repo"}}}]
           }}

        String.contains?(url, "/issues/77/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/graphql") ->
          empty_review_threads_response()

        String.contains?(url, "/pulls/77/reviews") ->
          {:ok, %{status: 200, body: reviews}}
      end
    end
  end
end
