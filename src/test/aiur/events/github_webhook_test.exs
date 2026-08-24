defmodule Aiur.Events.GithubWebhookTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubWebhook, Publisher}
  alias Aiur.Events.GithubWebhook.Normalizer
  alias Aiur.Events.GithubWebhookTest.OrchestratorWakeProbe
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

    test "unlabeled, closed, reopened and opened reconcile the same way, so out-of-order deliveries converge" do
      for action <- ["unlabeled", "closed", "reopened", "opened"] do
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
        "pull_request" => %{
          "number" => 901,
          "head" => %{"ref" => "aiur/42-slug", "repo" => %{"full_name" => @repo}}
        },
        "thread" => %{"node_id" => "PRRT_resolved", "is_resolved" => true, "updated_at" => "2026-08-21T10:00:00Z"}
      }

      assert {:reconcile,
              %{
                kind: :review_thread,
                ticket: "42",
                action: "resolved",
                thread_id: "PRRT_resolved",
                generation: "2026-08-21T10:00:00Z"
              }} =
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

    test "review-thread resolution changes request targeted comment reconciliation" do
      parent = self()

      for action <- ["resolved", "unresolved"] do
        delivery = review_thread_delivery(action)

        assert %{
                 status: :reconciled,
                 hint: %{
                   kind: :review_thread,
                   ticket: "42",
                   action: ^action,
                   thread_id: "PRRT_kwDOabc",
                   generation: "2026-08-21T12:00:00Z"
                 }
               } =
                 GithubWebhook.handle_delivery("pull_request_review_thread", delivery,
                   repo: @repo,
                   reconcile_fun: fn hint -> send(parent, {:reconcile, hint}) end
                 )

        assert_receive {:reconcile, %{kind: :review_thread, ticket: "42", action: ^action}}
      end
    end

    test "review-thread reconciliation uses the admitted delivery id when the timestamp is null" do
      delivery = Map.put(review_thread_delivery("unresolved"), "updated_at", nil)

      assert %{hint: %{generation: "delivery-123"}} =
               GithubWebhook.handle_delivery("pull_request_review_thread", delivery,
                 repo: @repo,
                 delivery_id: "delivery-123",
                 reconcile_fun: fn _hint -> :ok end
               )
    end

    test "review-thread deliveries reject malformed, irrelevant, and unmapped payloads" do
      delivery = review_thread_delivery("unresolved")

      assert {:drop, {:uninteresting_action, "pull_request_review_thread", "created"}} =
               delivery
               |> Map.put("action", "created")
               |> then(&Normalizer.normalize("pull_request_review_thread", &1, repo: @repo))

      assert {:error, {:malformed_payload, "pull_request_review_thread"}} =
               delivery
               |> Map.delete("thread")
               |> then(&Normalizer.normalize("pull_request_review_thread", &1, repo: @repo))

      # A payload whose pull request names no head repository at all is
      # malformed, not an untracked fork: there is no repo to compare, so the
      # drop reason would be a misleading `{:untracked_head_repository, nil}`
      # that reads like a tracking decision when the payload is simply missing
      # the field.
      assert {:error, {:malformed_payload, "pull_request_review_thread"}} =
               delivery
               |> put_in(["pull_request", "head"], %{"ref" => "aiur/42-slug"})
               |> then(&Normalizer.normalize("pull_request_review_thread", &1, repo: @repo))

      assert {:drop, {:unresolved_ticket, "pull_request_review_thread", "unresolved"}} =
               delivery
               |> put_in(["pull_request", "head", "ref"], "feature/no-ticket")
               |> then(&Normalizer.normalize("pull_request_review_thread", &1, repo: @repo))

      assert {:drop, {:untracked_head_repository, "contributor/fork"}} =
               delivery
               |> put_in(["pull_request", "head", "repo", "full_name"], "contributor/fork")
               |> then(&Normalizer.normalize("pull_request_review_thread", &1, repo: @repo))
    end

    test "review-thread hints bypass the generic reconcile debounce" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      for action <- ["resolved", "unresolved"] do
        assert %{status: :reconciled} =
                 GithubWebhook.handle_delivery("pull_request_review_thread", review_thread_delivery(action),
                   repo: @repo,
                   orchestrator: self()
                 )
      end

      assert_receive {:github_webhook_reconcile, %{action: "resolved"}}, 500
      assert_receive {:github_webhook_reconcile, %{action: "unresolved"}}, 500
      refute_receive :request_refresh, 100
    end

    test "a reconcile delivery wakes the dispatcher once per quiet period" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => 42, "updated_at" => "2026-06-24T12:00:00Z"}
      }

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      for _ <- 1..3 do
        assert %{status: :reconciled} =
                 GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)
      end

      # A burst of N deliveries in one second produces one wake, not N.
      assert_receive :request_refresh, 500
      refute_receive :request_refresh, 200
    end

    test "a PR state change publish wakes the dispatcher" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      delivery = %{
        "action" => "opened",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "its-everdred"},
        "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-slug", "sha" => "abc123"}}
      }

      assert %{status: :published, published: ["ticket.42.pr.opened"]} =
               GithubWebhook.handle_delivery("pull_request", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh, 500
    end

    test "a PR merge publish wakes the dispatcher" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "its-everdred"},
        "pull_request" => %{
          "number" => 901,
          "merged" => true,
          "head" => %{"ref" => "aiur/42-slug", "sha" => "abc123"},
          "updated_at" => "2026-06-24T12:00:00Z"
        }
      }

      assert %{status: :published, published: ["ticket.42.pr.merged"]} =
               GithubWebhook.handle_delivery("pull_request", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh, 500
    end

    test "a comment publish does not wake the dispatcher" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      assert %{status: :published, published: ["ticket.42.issue.commented"]} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(),
                 repo: @repo,
                 request_refresh_fun: request_refresh_fun
               )

      refute_receive :request_refresh, 200
    end

    test "a newly-opened ticket that already carries an active state label wakes the dispatcher" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      delivery = %{
        "action" => "opened",
        "repository" => %{"full_name" => @repo},
        "issue" => %{
          "number" => 42,
          "updated_at" => "2026-06-24T12:00:00Z",
          "labels" => [%{"name" => "aiur:todo"}]
        }
      }

      assert %{status: :reconciled, hint: %{kind: :issue_state, ticket: "42", action: "opened"}} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh, 500
    end

    test "a newly-opened issue with no actionable label is dropped and never wakes" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      delivery = %{
        "action" => "opened",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => 42, "updated_at" => "2026-06-24T12:00:00Z", "labels" => [%{"name" => "size:s"}]}
      }

      assert %{status: :dropped, reason: {:uninteresting_action, "issues", "opened"}} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      refute_receive :request_refresh, 200
    end

    test "a delivery with the default wake never raises, whatever the orchestrator answers" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => 42}
      }

      # The default `request_refresh_fun` is `Orchestrator.request_refresh/0`.
      # Against the live supervised orchestrator (running in the test app) it
      # succeeds; had the orchestrator been down it would return `:unavailable`
      # instead of raising (that unavailable path, and the window release that
      # goes with it, is pinned by "a wake that fails to land does not consume
      # the coalesce window"). Either way the delivery must not error.
      assert %{status: :reconciled} = GithubWebhook.handle_delivery("issues", delivery, repo: @repo)
    end

    # Blocking review finding #1: every other wake test injects
    # `:request_refresh_fun`, so the production default — the one behaviour that
    # distinguishes this wake from the raw `:run_poll_cycle` send it replaced —
    # was never executed by anything, and a mutant reverting the default to the
    # old `send(Process.whereis(Aiur.Orchestrator), :run_poll_cycle)` survived
    # the whole suite. This test runs the real default against a stand-in
    # registered as `Aiur.Orchestrator` (the live supervised orchestrator is
    # temporarily unregistered and restored on exit, the same swap
    # `agent_chat_broadcast_test` performs for its fake) and asserts the wake is
    # a `:request_refresh` GenServer call, not a raw `:run_poll_cycle` message.
    test "the real default wake is a request_refresh call, never a raw run_poll_cycle send" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      original = Process.whereis(Aiur.Orchestrator)
      if is_pid(original), do: Process.unregister(Aiur.Orchestrator)

      # `start_link` registers the probe under `Aiur.Orchestrator` now that the
      # live orchestrator has been unregistered for the duration of this test.
      {:ok, probe} = OrchestratorWakeProbe.start_link(self())
      Process.unlink(probe)

      on_exit(fn ->
        # Synchronous stop (unlike `Process.exit/2`, which is async and can
        # still hold the name when the live orchestrator is re-registered) so
        # the probe's registration is actually released first, then restore.
        if Process.alive?(probe) do
          try do
            GenServer.stop(probe)
          catch
            :exit, _ -> :ok
          end
        end

        if Process.whereis(Aiur.Orchestrator) == probe, do: Process.unregister(Aiur.Orchestrator)

        if is_pid(original) do
          try do
            Process.register(original, Aiur.Orchestrator)
          rescue
            ArgumentError -> :ok
          end
        end
      end)

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => 42}
      }

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo)

      assert_receive :request_refresh_called, 500
      refute_receive :run_poll_cycle_received, 200
    end

    # Non-blocking review finding #4: the leading-edge coalesce folds every
    # delivery inside the window into the leading cycle, so state deposited just
    # after that cycle read would otherwise wait out the full poll interval. A
    # trailing wake at window close picks it up.
    test "a delivery folded into the coalesce window still gets a trailing wake" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)
      override_reconcile_debounce(200)

      # The trailing wake fires from a spawned process, so the seam must send to
      # an explicit pid rather than `self()` (which would resolve to the spawned
      # process and lose the message).
      parent = self()
      request_refresh_fun = fn -> send(parent, :request_refresh) end

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => 42, "updated_at" => "2026-06-24T12:00:00Z"}
      }

      # Leading edge: the first delivery wakes immediately.
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh, 500

      # A second delivery inside the window deposits its state and is coalesced.
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      refute_receive :request_refresh, 100

      # At window close the trailing wake fires, so the second delivery's
      # deposit is acted on before the next scheduled tick.
      assert_receive :request_refresh, 1_000
    end

    # Blocking review finding #3, second half: the coalesce window is sized from
    # the poll cadence (`interval_seconds / 5`, floored at 2s) rather than being
    # a flat 2s, which is what bounds sustained webhook traffic to a fixed
    # multiple of the poll rate instead of a 60x amplification. Every other wake
    # test either injects the Application override or runs inside a single
    # window, so a mutant collapsing the sizing back to the flat floor survived
    # them all. This test reads the *computed* window: with a 15s poll interval
    # the window is 3s, so a delivery at 2.4s — past the flat floor, inside the
    # sized window — must still coalesce.
    test "the coalesce window is sized from the poll interval, not a flat floor" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      # No Application override: this test must exercise the computed branch.
      previous = Application.get_env(:aiur, :github_webhook_reconcile_debounce_ms)
      Application.delete_env(:aiur, :github_webhook_reconcile_debounce_ms)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:aiur, :github_webhook_reconcile_debounce_ms)
        else
          Application.put_env(:aiur, :github_webhook_reconcile_debounce_ms, previous)
        end
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: @repo,
        tracker_label_prefix: "aiur",
        poll_interval_seconds: 15
      )

      assert Aiur.Config.settings!().polling.interval_seconds == 15

      # The trailing wake fires from a spawned process, so the seam must send to
      # an explicit pid rather than `self()`.
      parent = self()
      request_refresh_fun = fn -> send(parent, :request_refresh) end

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => 42, "updated_at" => "2026-06-24T12:00:00Z"}
      }

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh, 500

      # Past a flat 2s floor, still inside the 3s window the 15s poll interval
      # implies. A flat-floor mutant claims a fresh leading edge here and wakes.
      Process.sleep(2_400)

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      refute_receive :request_refresh, 300
    end

    # Non-blocking review finding #4: a wake that fails to land (the orchestrator
    # is not running) used to consume the coalesce window, so the failure also
    # suppressed the next window's worth of wakes. Releasing the window on
    # failure lets the next delivery retry.
    test "a wake that fails to land does not consume the coalesce window" do
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)
      override_reconcile_debounce(60_000)

      parent = self()

      request_refresh_fun = fn ->
        send(parent, :request_refresh_attempted)
        :unavailable
      end

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => 42}
      }

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh_attempted, 500

      # With a 60s window a stuck failed claim would coalesce this second
      # delivery; the release means it claims a fresh leading edge and wakes.
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh_attempted, 500
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

  # Test seam for the coalesce window: the production debounce is sized from
  # `polling.interval_seconds` (default 120s => 24s), far too long for a test to
  # wait through. The tail reads an Application override ahead of the computed
  # value, exactly like the receiver's `:webhook_admission_timeout_ms`.
  defp override_reconcile_debounce(ms) do
    previous = Application.get_env(:aiur, :github_webhook_reconcile_debounce_ms)
    Application.put_env(:aiur, :github_webhook_reconcile_debounce_ms, ms)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :github_webhook_reconcile_debounce_ms)
      else
        Application.put_env(:aiur, :github_webhook_reconcile_debounce_ms, previous)
      end
    end)
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

  defp review_thread_delivery(action) do
    %{
      "action" => action,
      "repository" => %{"full_name" => @repo},
      "thread" => %{
        "id" => 88_001,
        "node_id" => "PRRT_kwDOabc",
        "comments" => 1
      },
      "updated_at" => "2026-08-21T12:00:00Z",
      "pull_request" => %{
        "number" => 901,
        "head" => %{"ref" => "aiur/42-slug", "sha" => "deadbeef", "repo" => %{"full_name" => @repo}}
      }
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

defmodule Aiur.Events.GithubWebhookTest.OrchestratorWakeProbe do
  @moduledoc """
  Stand-in registered as `Aiur.Orchestrator` so the delivery tail's *default*
  wake (`Orchestrator.request_refresh/0`) has a real process to call. Records a
  `:request_refresh` GenServer call as `:request_refresh_called` and a raw
  `:run_poll_cycle` message as `:run_poll_cycle_received`, so a test can tell
  the two wake shapes apart — the mutant that reverts the default to a raw
  `:run_poll_cycle` send would fail the `refute_receive`.
  """
  use GenServer

  # `start_link/1` is the conventional constructor, not a GenServer callback.
  def start_link(test) do
    GenServer.start_link(__MODULE__, test, name: Aiur.Orchestrator)
  end

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call(:request_refresh, _from, test) do
    send(test, :request_refresh_called)
    {:reply, %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll", "reconcile"]}, test}
  end

  # While the probe briefly holds the `Aiur.Orchestrator` name, any unrelated
  # caller must get a fast reply rather than a 5s GenServer timeout.
  @impl true
  def handle_call(_request, _from, test), do: {:reply, :unavailable, test}

  @impl true
  def handle_info(:run_poll_cycle, test) do
    send(test, :run_poll_cycle_received)
    {:noreply, test}
  end

  @impl true
  def handle_info(_message, test), do: {:noreply, test}
end
