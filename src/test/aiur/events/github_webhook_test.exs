defmodule Aiur.Events.GithubWebhookTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubWebhook, Publisher}
  alias Aiur.Events.GithubWebhook.Normalizer
  alias Aiur.GitHub.ReadCache
  alias Aiur.Webhooks
  alias Aiur.Webhooks.ModeRegistry
  alias Aiur.Workflow

  @repo "owner/repo"
  @dedup_table Aiur.Events.Publisher.Dedup

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: @repo,
      tracker_label_prefix: "aiur"
    )

    Publisher.set_tracked_fn(fn _ -> true end)
    clear_dedup()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      Publisher.set_tracked_fn(fn _ -> true end)
      clear_dedup()

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end)

    :ok
  end

  describe "tracked-repo filter" do
    test "a delivery for an untracked repository is dropped and never publishes" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      delivery = issue_comment_delivery(%{"full_name" => "someone-else/other-repo"})

      assert %{status: :dropped, reason: {:untracked_repository, "someone-else/other-repo"}} =
               GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

      refute_receive {:event, %{topic: "ticket.42.issue.commented"}}, 200
    end

    test "the tracked repository matches case-insensitively" do
      assert {:publish, [_triple]} =
               Normalizer.normalize("issue_comment", issue_comment_delivery(%{"full_name" => "Owner/Repo"}), repo: @repo)
    end

    # Resolving a review comment's thread costs a GraphQL point. A delivery for
    # a repository the fleet does not track is dropped anyway, so the resolver
    # must never be consulted for one (#2081).
    test "a review comment for an untracked repository never consults the thread resolver" do
      delivery = %{
        "action" => "created",
        "repository" => %{"full_name" => "someone-else/other-repo"},
        "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-some-slug"}},
        "comment" => %{
          "id" => 7_007,
          "node_id" => "PRRC_kwDOabc123",
          "body" => "inline",
          "user" => %{"login" => "its-everdred"}
        }
      }

      assert %{status: :dropped, reason: {:untracked_repository, "someone-else/other-repo"}} =
               GithubWebhook.handle_delivery("pull_request_review_comment", delivery,
                 repo: @repo,
                 request_fun: fn _request -> flunk("resolver must not be called for an untracked repository") end
               )
    end

    test "a delivery with no repository is rejected as malformed" do
      assert %{status: :error, reason: :missing_repository} =
               GithubWebhook.handle_delivery("issue_comment", Map.delete(issue_comment_delivery(), "repository"), repo: @repo)
    end
  end

  describe "unrecognized and malformed deliveries" do
    test "an unrecognized event type is ignored without crashing" do
      assert %{status: :dropped, reason: {:unsupported_event, "deployment_status"}} =
               GithubWebhook.handle_delivery("deployment_status", issue_comment_delivery(), repo: @repo)
    end

    test "a non-string event type is ignored" do
      assert %{status: :dropped, reason: {:unsupported_event, nil}} =
               GithubWebhook.handle_delivery(nil, issue_comment_delivery(), repo: @repo)
    end

    test "a non-map payload is rejected without raising" do
      assert %{status: :error, reason: {:malformed_payload, "issue_comment"}} =
               GithubWebhook.handle_delivery("issue_comment", "not json", repo: @repo)
    end

    test "a partial payload missing the comment is rejected" do
      partial = Map.delete(issue_comment_delivery(), "comment")

      assert %{status: :error, reason: {:malformed_payload, "issue_comment"}} =
               GithubWebhook.handle_delivery("issue_comment", partial, repo: @repo)
    end

    test "a review delivery with no pull request is rejected" do
      delivery = %{
        "action" => "submitted",
        "repository" => %{"full_name" => @repo},
        "review" => %{"id" => 1, "state" => "CHANGES_REQUESTED", "user" => %{"login" => "its-everdred"}}
      }

      assert %{status: :error, reason: {:malformed_payload, "pull_request"}} =
               GithubWebhook.handle_delivery("pull_request_review", delivery, repo: @repo)
    end

    test "an exception raised inside the publish tail is contained" do
      assert %{status: :error, reason: {:exception, "boom"}} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(),
                 repo: @repo,
                 publish_fun: fn _topic, _payload, _opts -> raise "boom" end
               )
    end
  end

  describe "issue comments" do
    test "an Agent Workpad comment is dropped, matching the poller" do
      delivery =
        issue_comment_delivery(%{"full_name" => @repo}, %{
          "id" => 1,
          "body" => "## Agent Workpad\n\n- [x] pushed",
          "user" => %{"login" => "its-everdred"}
        })

      assert %{status: :dropped, reason: :agent_workpad_comment} =
               GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)
    end

    test "a deleted-comment action does not publish" do
      delivery = Map.put(issue_comment_delivery(), "action", "deleted")

      assert %{status: :dropped, reason: {:uninteresting_action, "issue_comment", "deleted"}} =
               GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)
    end

    test "an edited comment publishes, matching the poller's updated_at cursor behaviour" do
      delivery = Map.put(issue_comment_delivery(), "action", "edited")

      assert {:publish, [{"ticket.42.issue.commented", _payload, _opts}]} =
               Normalizer.normalize("issue_comment", delivery, repo: @repo)
    end

    # A PR-attached issue_comment carries no head ref, so the ticket comes from
    # the closing keyword every Aiur PR description opens with.
    test "a comment on a pull request maps to the ticket named by the PR body" do
      delivery =
        issue_comment_delivery()
        |> put_in(["issue"], %{
          "number" => 901,
          "body" => "Closes #1678\n\n# Problem\n...",
          "pull_request" => %{"url" => "https://api.github.com/repos/owner/repo/pulls/901"}
        })

      assert {:publish, [{"ticket.1678.issue.commented", payload, opts}]} =
               Normalizer.normalize("issue_comment", delivery, repo: @repo)

      assert payload.issue_number == "1678"
      # The dedup parent is the PR number, exactly as publish_pr_issue_comment/4 keys it.
      assert opts[:dedup_key] == {@repo, "issue_comment:901", "1001"}
    end

    test "a pull request comment whose body names no ticket is dropped for the poller to pick up" do
      delivery =
        issue_comment_delivery()
        |> put_in(["issue"], %{"number" => 901, "body" => "no keyword here", "pull_request" => %{}})

      assert {:drop, {:unresolved_ticket, "issue_comment", "901"}} =
               Normalizer.normalize("issue_comment", delivery, repo: @repo)
    end
  end

  describe "pull request reviews" do
    test "an APPROVED review does not wake an agent, matching the poller's actionable filter" do
      assert {:drop, {:non_actionable_review, "APPROVED"}} =
               Normalizer.normalize("pull_request_review", review_delivery("APPROVED", "looks good"), repo: @repo)
    end

    test "an empty-bodied COMMENTED container does not wake an agent" do
      assert {:drop, {:non_actionable_review, "COMMENTED"}} =
               Normalizer.normalize("pull_request_review", review_delivery("COMMENTED", ""), repo: @repo)
    end

    test "a COMMENTED review with a body wakes an agent" do
      assert {:publish, [{"ticket.42.pr.review_comment", _payload, _opts}]} =
               Normalizer.normalize("pull_request_review", review_delivery("COMMENTED", "one thought"), repo: @repo)
    end

    test "a review on a non-ticket branch is dropped" do
      delivery = put_in(review_delivery(), ["pull_request", "head", "ref"], "someone/experiment")

      assert {:drop, {:unresolved_ticket, "pull_request", 901}} =
               Normalizer.normalize("pull_request_review", delivery, repo: @repo)
    end
  end

  describe "pull request lifecycle" do
    test "closed + merged publishes pr.merged with contamination bypassed, matching the firehose" do
      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "its-everdred"},
        "pull_request" => %{
          "number" => 901,
          "merged" => true,
          "updated_at" => "2026-06-24T12:00:00Z",
          "head" => %{"ref" => "aiur/42-slug", "sha" => "deadbeef"}
        }
      }

      assert {:publish, [{"ticket.42.pr.merged", payload, opts}]} =
               Normalizer.normalize("pull_request", delivery, repo: @repo)

      assert payload.action == "closed"
      assert opts[:bypass_contamination] == true
      assert opts[:dedup_key] == {@repo, "pr:closed:901", "deadbeef"}
    end

    test "closed without merge publishes nothing, matching the firehose" do
      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "its-everdred"},
        "pull_request" => %{
          "number" => 901,
          "merged" => false,
          "head" => %{"ref" => "aiur/42-slug", "sha" => "deadbeef"}
        }
      }

      assert {:drop, {:uninteresting_action, "pull_request", "closed"}} =
               Normalizer.normalize("pull_request", delivery, repo: @repo)
    end
  end

  describe "state-owned events reconcile rather than publishing a parallel shape" do
    test "an issues labeled delivery asks the orchestrator to reconcile now" do
      parent = self()

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => 42, "updated_at" => "2026-06-24T12:00:00Z"},
        "label" => %{"name" => "agent:rework"}
      }

      assert %{status: :reconciled, hint: %{kind: :issue_state, ticket: "42", action: "labeled"}} =
               GithubWebhook.handle_delivery("issues", delivery,
                 repo: @repo,
                 reconcile_fun: fn hint -> send(parent, {:reconcile, hint}) end
               )

      assert_receive {:reconcile, %{kind: :issue_state, ticket: "42"}}
    end

    test "unlabeled and closed reconcile the same way, so out-of-order deliveries converge" do
      for action <- ["unlabeled", "closed", "reopened"] do
        delivery = %{
          "action" => action,
          "repository" => %{"full_name" => @repo},
          "issue" => %{"number" => 42, "updated_at" => "2026-06-24T12:00:00Z"}
        }

        assert {:reconcile, %{kind: :issue_state, ticket: "42", action: ^action}} =
                 Normalizer.normalize("issues", delivery, repo: @repo)
      end
    end

    test "a completed check suite reconciles the CI lifecycle for its ticket" do
      delivery = %{
        "action" => "completed",
        "repository" => %{"full_name" => @repo},
        "check_suite" => %{
          "head_sha" => "deadbeef",
          "conclusion" => "failure",
          "pull_requests" => [%{"number" => 901, "head" => %{"ref" => "aiur/42-slug"}}]
        }
      }

      assert {:reconcile, %{kind: :ci, tickets: ["42"], head_sha: "deadbeef", conclusion: "failure"}} =
               Normalizer.normalize("check_suite", delivery, repo: @repo)
    end

    test "a completed check run reconciles the same way" do
      delivery = %{
        "action" => "completed",
        "repository" => %{"full_name" => @repo},
        "check_run" => %{
          "head_sha" => "deadbeef",
          "conclusion" => "success",
          "pull_requests" => [%{"number" => 901, "head" => %{"ref" => "aiur/42-slug"}}]
        }
      }

      assert {:reconcile, %{kind: :ci, tickets: ["42"], source: "check_run"}} =
               Normalizer.normalize("check_run", delivery, repo: @repo)
    end

    test "a resolved pull request review thread reconciles without publishing a comment" do
      delivery = %{
        "action" => "resolved",
        "repository" => %{"full_name" => @repo},
        "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-slug"}},
        "thread" => %{"node_id" => "PRRT_resolved", "is_resolved" => true, "updated_at" => "2026-08-21T10:00:00Z"}
      }

      assert {:reconcile, %{kind: :review_threads, ticket: "42", pull_request: 901, source: "pull_request_review_thread"}} =
               Normalizer.normalize("pull_request_review_thread", delivery, repo: @repo)
    end

    test "an in-progress check is dropped" do
      delivery = %{
        "action" => "created",
        "repository" => %{"full_name" => @repo},
        "check_run" => %{"head_sha" => "deadbeef"}
      }

      assert {:drop, {:uninteresting_action, "check_run", "created"}} =
               Normalizer.normalize("check_run", delivery, repo: @repo)
    end

    test "a synchronize push invalidates review state through the CI reconciler" do
      delivery = %{
        "action" => "synchronize",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "its-everdred"},
        "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-slug", "sha" => "newsha"}}
      }

      assert {:reconcile, %{kind: :ci, ticket: "42", head_sha: "newsha", action: "synchronize"}} =
               Normalizer.normalize("pull_request", delivery, repo: @repo)
    end

    test "the orchestrator is nudged to poll now, and a delivery burst is coalesced into one nudge" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => 42, "updated_at" => "2026-06-24T12:00:00Z"}
      }

      for _ <- 1..3 do
        assert %{status: :reconciled} =
                 GithubWebhook.handle_delivery("issues", delivery, repo: @repo, orchestrator: self())
      end

      assert_receive :run_poll_cycle, 500
      refute_receive :run_poll_cycle, 200
    end

    test "no orchestrator running is not an error" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => 42}
      }

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, orchestrator: :no_such_orchestrator)
    end

    test "a check suite for an untracked branch is dropped" do
      delivery = %{
        "action" => "completed",
        "repository" => %{"full_name" => @repo},
        "check_suite" => %{"head_sha" => "deadbeef", "pull_requests" => [%{"head" => %{"ref" => "develop"}}]}
      }

      assert {:drop, {:unresolved_ticket, "check_suite", "completed"}} =
               Normalizer.normalize("check_suite", delivery, repo: @repo)
    end
  end

  # W-6 (#1683) treats a repo as webhook-backed only once a delivery has been
  # observed, and exposes `Aiur.Webhooks.record_delivery/2` as the seam "the
  # receiver" calls. This module is that receiver's tail, so these assert the
  # seam is actually wired: each one reads the mode back through the registry
  # rather than the return value, so dropping the call turns them red.
  describe "webhook proof of life" do
    test "a delivery retires the read-cache entries for the issue it carries" do
      request = graphql_request(42)

      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(), repo: @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a delivery for the tracked repo promotes it from configured-unproven to webhook-backed" do
      registry = start_mode_registry([@repo])

      assert Webhooks.polling_reason(@repo, server: registry) == :configured_unproven

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(), repo: @repo, server: registry)

      assert Webhooks.transport(@repo, server: registry) == :webhook
      assert Webhooks.polling_reason(@repo, server: registry) == nil
    end

    test "an event type the fleet ignores still proves the webhook works" do
      registry = start_mode_registry([@repo])

      assert %{status: :dropped, reason: {:unsupported_event, "star"}} =
               GithubWebhook.handle_delivery("star", %{"action" => "created", "repository" => %{"full_name" => @repo}},
                 repo: @repo,
                 server: registry
               )

      assert Webhooks.transport(@repo, server: registry) == :webhook
    end

    test "a delivery for an untracked repository proves nothing for either repo" do
      untracked = "someone-else/other-repo"
      registry = start_mode_registry([@repo, untracked])

      assert %{status: :dropped, reason: {:untracked_repository, ^untracked}} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(%{"full_name" => untracked}),
                 repo: @repo,
                 server: registry
               )

      assert Webhooks.transport(untracked, server: registry) == :polling
      assert Webhooks.transport(@repo, server: registry) == :polling
    end

    test "a malformed delivery records nothing and does not crash the tail" do
      registry = start_mode_registry([@repo])

      assert %{status: :error} = GithubWebhook.handle_delivery("issue_comment", "not-a-map", repo: @repo, server: registry)

      assert %{status: :error, reason: :missing_repository} =
               GithubWebhook.handle_delivery("issue_comment", Map.delete(issue_comment_delivery(), "repository"),
                 repo: @repo,
                 server: registry
               )

      assert Webhooks.transport(@repo, server: registry) == :polling
    end

    test "the tail is unaffected when no mode registry is running" do
      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(),
                 repo: @repo,
                 server: :no_mode_registry_here
               )
    end
  end

  defp start_mode_registry(configured_repos) do
    name = :"webhook_tail_registry_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised({ModeRegistry, name: name, configured_repos: configured_repos, silence_threshold_ms: 900_000, sweep_interval_ms: 3_600_000, alert_fun: fn _name, _message, _opts -> :ok end})

    name
  end

  defp graphql_request(number) do
    %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "t",
      body: %{
        "query" => "query Q($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { t0: issueOrPullRequest(number: #{number}) { ... on Issue { title } } } }",
        "variables" => %{"owner" => "owner", "repo" => "repo"}
      },
      caller: "issue_relationships"
    }
  end

  defp issue_comment_delivery(repository \\ %{"full_name" => @repo}, comment \\ nil) do
    %{
      "action" => "created",
      "repository" => repository,
      "issue" => %{"number" => 42, "title" => "a ticket"},
      "comment" =>
        comment ||
          %{
            "id" => 1_001,
            "body" => "please rework this",
            "created_at" => "2026-06-24T12:00:00Z",
            "updated_at" => "2026-06-24T12:00:00Z",
            "user" => %{"login" => "its-everdred"}
          },
      "sender" => %{"login" => "its-everdred"}
    }
  end

  defp review_delivery(state \\ "CHANGES_REQUESTED", body \\ "needs work") do
    %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "sender" => %{"login" => "its-everdred"},
      "review" => %{
        "id" => 55_001,
        "state" => state,
        "body" => body,
        "submitted_at" => "2026-06-24T12:00:00Z",
        "user" => %{"login" => "its-everdred"}
      },
      "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-slug", "sha" => "deadbeef"}}
    }
  end

  defp clear_dedup do
    case :ets.whereis(@dedup_table) do
      :undefined -> :ok
      _table -> :ets.delete_all_objects(@dedup_table)
    end

    :ok
  end
end
