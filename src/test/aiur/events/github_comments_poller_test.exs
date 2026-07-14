defmodule Aiur.Events.GithubCommentsPollerTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubCommentsPoller, Publisher}
  alias Aiur.GitHub.AgentCommentOrigins
  alias Aiur.GitHub.CodeOwners
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
    end)

    :ok
  end

  test "returns default cursor without calling GitHub when there are no targets" do
    assert {:ok, %{count: 0, since: %{}, errors: []}} =
             GithubCommentsPoller.poll(["", "  "], boot_time: 1_782_302_400)
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
    assert_receive {:requested, legacy_pulls_url}
    assert_receive {:requested, readable_pulls_url}
    refute_receive {:requested, _url}, 100

    assert String.contains?(issue_comments_url, "/issues/42/comments?")
    assert String.contains?(legacy_pulls_url, "head=owner%3Aaiur%2F42")
    assert String.contains?(readable_pulls_url, "/pulls?")
    refute String.contains?(readable_pulls_url, "head=")
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

  test "defers a corrupt provenance lookup without advancing the poll cursor" do
    path = Path.join(System.tmp_dir!(), "aiur-comment-poller-corrupt-#{System.unique_integer([:positive])}.json")
    previous_path = Application.get_env(:aiur, :agent_comment_origins_path)
    Application.put_env(:aiur, :agent_comment_origins_path, path)
    :ok = File.write(path, "not json")

    on_exit(fn ->
      File.rm_rf(path <> ".tickets")
      File.rm(path)

      if previous_path do
        Application.put_env(:aiur, :agent_comment_origins_path, previous_path)
      else
        Application.delete_env(:aiur, :agent_comment_origins_path)
      end
    end)

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 1013,
                 "body" => "must not become trusted while provenance is corrupt",
                 "updated_at" => "2026-06-24T12:00:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 0, since: %{"42" => "2026-06-24T11:00:00Z"}, errors: errors}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert [{"42", {:origin_unresolved, {:store_read_failed, _reason}}}] = errors
  end

  test "defers parseable but invalid provenance state without advancing the poll cursor" do
    path = Path.join(System.tmp_dir!(), "aiur-comment-poller-invalid-#{System.unique_integer([:positive])}.json")
    previous_path = Application.get_env(:aiur, :agent_comment_origins_path)
    Application.put_env(:aiur, :agent_comment_origins_path, path)
    :ok = File.write(path, ~s({"origins":{"42":"not-a-list"},"pending":{}}))

    on_exit(fn ->
      File.rm_rf(path <> ".tickets")
      File.rm(path)

      if previous_path do
        Application.put_env(:aiur, :agent_comment_origins_path, previous_path)
      else
        Application.delete_env(:aiur, :agent_comment_origins_path)
      end
    end)

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 1014,
                 "body" => "must not become trusted while provenance shape is invalid",
                 "updated_at" => "2026-06-24T12:00:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 0, since: %{"42" => "2026-06-24T11:00:00Z"}, errors: errors}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert [{"42", {:origin_unresolved, :invalid_origins}}] = errors
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
          {:ok, %{status: 200, body: [%{"number" => 77}]}}

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

  test "marks a recorded agent review reply while leaving shared-login trust intact" do
    comment_id = System.unique_integer([:positive])
    :ok = AgentCommentOrigins.record("42", %{"id" => comment_id})
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: [%{"number" => 77}]}}

        String.contains?(url, "/issues/77/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/graphql") ->
          review_threads_response([
            %{
              "id" => "PRRT_agent_origin",
              "isResolved" => false,
              "path" => "lib/app.ex",
              "line" => 12,
              "comments" => %{"nodes" => [review_thread_comment(comment_id, "its-everdred", "agent reply")]}
            }
          ])
      end
    end

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-25T00:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: "ticket.42.pr.review_comment",
                      author_trusted?: true,
                      comment_origin: "agent",
                      comment: %{"id" => ^comment_id}
                    }},
                   500

    assert AgentCommentOrigins.origin("42", %{"id" => comment_id + 1}) == {:ok, :external}
    stop_codeowners(codeowners)
  end

  test "publishes a later trusted human reply from the same review thread" do
    agent_comment_id = System.unique_integer([:positive])
    human_comment_id = agent_comment_id + 1
    :ok = AgentCommentOrigins.record("42", %{"id" => agent_comment_id})
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")
    codeowners = ensure_codeowners!("* @its-everdred\n")
    {:ok, poll_count} = Agent.start_link(fn -> 0 end)

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: [%{"number" => 77}]}}

        String.contains?(url, "/issues/77/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/graphql") ->
          count = Agent.get_and_update(poll_count, fn current -> {current, current + 1} end)

          comments =
            if count == 0 do
              [review_thread_comment(agent_comment_id, "its-everdred", "agent reply")]
            else
              [
                review_thread_comment(agent_comment_id, "its-everdred", "agent reply"),
                review_thread_comment(human_comment_id, "its-everdred", "human follow-up")
              ]
            end

          review_threads_response([
            %{
              "id" => "PRRT_shared_login",
              "isResolved" => false,
              "path" => "lib/app.ex",
              "line" => 12,
              "comments" => %{"nodes" => comments}
            }
          ])
      end
    end

    assert {:ok, _} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-25T00:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event, %{comment_origin: "agent", comment: %{"id" => ^agent_comment_id}}}, 500

    assert {:ok, _} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-25T00:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      author_trusted?: true,
                      comment_origin: "external",
                      comment: %{"id" => ^human_comment_id}
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
          {:ok, %{status: 200, body: [%{"number" => 77}]}}

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
          {:ok, %{status: 200, body: [%{"number" => 77}]}}

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

        String.contains?(url, "/pulls?") and not String.contains?(url, "aiur%2F43") and not String.contains?(url, "aiur/43") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/issues/43/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") and String.contains?(url, "aiur%2F43") ->
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
              errors: [{"43", {:pr_lookup, {:github, :timeout, %{reason: :timeout}}}}]
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

  defp ensure_codeowners!(contents) do
    case Process.whereis(CodeOwners) do
      pid when is_pid(pid) ->
        previous_allowlist = CodeOwners.snapshot(pid)
        :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(["its-everdred"])})

        %{pid: pid, path: nil, owned?: false, previous_allowlist: previous_allowlist}

      nil ->
        path =
          Path.join(System.tmp_dir!(), "aiur-codeowners-#{System.unique_integer([:positive])}")

        File.write!(path, contents)

        {:ok, pid} = CodeOwners.start_link(path: path, refresh_seconds: 3600)

        %{pid: pid, path: path, owned?: true}
    end
  end

  defp ensure_configured_codeowners!(contents) do
    path = Path.join(System.tmp_dir!(), "aiur-codeowners-#{System.unique_integer([:positive])}")
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
    if Process.alive?(pid), do: GenServer.stop(pid)
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
end
