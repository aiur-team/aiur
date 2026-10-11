defmodule Aiur.Events.GithubWebhookTest do
  use Aiur.TestSupport.WebhookTailCase

  alias Aiur.Events.{Exchange, GithubWebhook}
  alias Aiur.Events.GithubWebhook.Normalizer
  alias Aiur.GitHub.ReadCache
  alias Aiur.Webhooks

  @repo "owner/repo"

  describe "tracked-repo filter" do
    test "a delivery for an untracked repository is dropped and never publishes" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(ticket_topic)

      delivery = issue_comment_delivery(ticket, %{"full_name" => "someone-else/other-repo"})

      assert %{status: :dropped, reason: {:untracked_repository, "someone-else/other-repo"}} =
               GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

      refute_receive {:event, %{topic: ^ticket_topic}}, 200
    end

    test "the tracked repository matches case-insensitively" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      assert {:publish, [_triple]} =
               Normalizer.normalize("issue_comment", issue_comment_delivery(ticket, %{"full_name" => "Owner/Repo"}), repo: @repo)
    end

    test "a review comment for an untracked repository never consults the thread resolver" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      delivery = %{
        "action" => "created",
        "repository" => %{"full_name" => "someone-else/other-repo"},
        "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/#{ticket}-some-slug"}},
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
      ticket = Integer.to_string(System.unique_integer([:positive]))

      assert %{status: :error, reason: :missing_repository} =
               GithubWebhook.handle_delivery("issue_comment", Map.delete(issue_comment_delivery(ticket), "repository"), repo: @repo)
    end
  end

  describe "unrecognized and malformed deliveries" do
    test "an unrecognized event type is ignored without crashing" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      assert %{status: :dropped, reason: {:unsupported_event, "deployment_status"}} =
               GithubWebhook.handle_delivery("deployment_status", issue_comment_delivery(ticket), repo: @repo)
    end

    test "a non-string event type is ignored" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      assert %{status: :dropped, reason: {:unsupported_event, nil}} =
               GithubWebhook.handle_delivery(nil, issue_comment_delivery(ticket), repo: @repo)
    end

    test "a non-map payload is rejected without raising" do
      assert %{status: :error, reason: {:malformed_payload, "issue_comment"}} =
               GithubWebhook.handle_delivery("issue_comment", "not json", repo: @repo)
    end

    test "a partial payload missing the comment is rejected" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      partial = Map.delete(issue_comment_delivery(ticket), "comment")

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
      ticket = Integer.to_string(System.unique_integer([:positive]))

      assert %{status: :error, reason: {:exception, "boom"}} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(ticket),
                 repo: @repo,
                 publish_fun: fn _topic, _payload, _opts -> raise "boom" end
               )
    end
  end

  describe "issue comments" do
    test "an Agent Workpad comment is dropped, matching the poller" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      delivery =
        issue_comment_delivery(ticket, %{"full_name" => @repo}, %{
          "id" => 1,
          "body" => "## Agent Workpad\n\n- [x] pushed",
          "user" => %{"login" => "its-everdred"}
        })

      assert %{status: :dropped, reason: :agent_workpad_comment} =
               GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)
    end

    test "a deleted-comment action does not publish" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      delivery = Map.put(issue_comment_delivery(ticket), "action", "deleted")

      assert %{status: :dropped, reason: {:uninteresting_action, "issue_comment", "deleted"}} =
               GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)
    end

    test "an edited comment publishes, matching the poller's updated_at cursor behaviour" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      delivery = Map.put(issue_comment_delivery(ticket), "action", "edited")

      assert {:publish, [{^ticket_topic, _payload, _opts}]} =
               Normalizer.normalize("issue_comment", delivery, repo: @repo)
    end

    # A PR-attached issue_comment carries no head ref, so the ticket comes from
    # the closing keyword every Aiur PR description opens with.
    test "a comment on a pull request maps to the ticket named by the PR body" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      delivery =
        issue_comment_delivery(ticket)
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
      ticket = Integer.to_string(System.unique_integer([:positive]))

      delivery =
        issue_comment_delivery(ticket)
        |> put_in(["issue"], %{"number" => 901, "body" => "no keyword here", "pull_request" => %{}})

      assert {:drop, {:unresolved_ticket, "issue_comment", "901"}} =
               Normalizer.normalize("issue_comment", delivery, repo: @repo)
    end
  end

  describe "pull request reviews" do
    test "an APPROVED review does not wake an agent, matching the poller's actionable filter" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      assert {:drop, {:non_actionable_review, "APPROVED"}} =
               Normalizer.normalize("pull_request_review", review_delivery(ticket, "APPROVED", "looks good"), repo: @repo)
    end

    test "an empty-bodied COMMENTED container does not wake an agent" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      assert {:drop, {:non_actionable_review, "COMMENTED"}} =
               Normalizer.normalize("pull_request_review", review_delivery(ticket, "COMMENTED", ""), repo: @repo)
    end

    test "a COMMENTED review with a body wakes an agent" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.pr.review_comment"

      assert {:publish, [{^ticket_topic, _payload, _opts}]} =
               Normalizer.normalize("pull_request_review", review_delivery(ticket, "COMMENTED", "one thought"), repo: @repo)
    end

    test "a review on a non-ticket branch is dropped" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      delivery = put_in(review_delivery(ticket), ["pull_request", "head", "ref"], "someone/experiment")

      assert {:drop, {:unresolved_ticket, "pull_request", 901}} =
               Normalizer.normalize("pull_request_review", delivery, repo: @repo)
    end
  end

  describe "pull request lifecycle" do
    test "closed + merged publishes pr.merged with contamination bypassed, matching the firehose" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.pr.merged"

      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "its-everdred"},
        "pull_request" => %{
          "number" => 901,
          "merged" => true,
          "updated_at" => "2026-06-24T12:00:00Z",
          "head" => %{"ref" => "aiur/#{ticket}-slug", "sha" => "deadbeef"}
        }
      }

      assert {:publish, [{^ticket_topic, payload, opts}]} =
               Normalizer.normalize("pull_request", delivery, repo: @repo)

      assert payload.action == "closed"
      assert opts[:bypass_contamination] == true
      assert opts[:dedup_key] == {@repo, "pr:closed:901", "deadbeef"}
    end

    test "closed without merge publishes nothing, matching the firehose" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "its-everdred"},
        "pull_request" => %{
          "number" => 901,
          "merged" => false,
          "head" => %{"ref" => "aiur/#{ticket}-slug", "sha" => "deadbeef"}
        }
      }

      assert {:drop, {:uninteresting_action, "pull_request", "closed"}} =
               Normalizer.normalize("pull_request", delivery, repo: @repo)
    end
  end

  # W-6 (#1683) treats a repo as webhook-backed only once a delivery has been
  # observed, and exposes `Aiur.Webhooks.record_delivery/2` as the seam "the
  # receiver" calls. This module is that receiver's tail, so these assert the
  # seam is actually wired: each one reads the mode back through the registry
  # rather than the return value, so dropping the call turns them red.
  describe "webhook proof of life" do
    test "a delivery retires the read-cache entries for the issue it carries" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      request = graphql_request(String.to_integer(ticket))
      assert {:ok, _response} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "first"}} end)

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(ticket), repo: @repo)

      assert {:ok, %{body: "second"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "second"}} end)
    end

    test "a delivery for the tracked repo promotes it from configured-unproven to webhook-backed" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      registry = start_mode_registry([@repo])
      assert Webhooks.polling_reason(@repo, server: registry) == :configured_unproven

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(ticket), repo: @repo, server: registry)

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
      ticket = Integer.to_string(System.unique_integer([:positive]))
      untracked = "someone-else/other-repo"
      registry = start_mode_registry([@repo, untracked])

      assert %{status: :dropped, reason: {:untracked_repository, ^untracked}} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(ticket, %{"full_name" => untracked}),
                 repo: @repo,
                 server: registry
               )

      assert Webhooks.transport(untracked, server: registry) == :polling
      assert Webhooks.transport(@repo, server: registry) == :polling
    end

    test "a malformed delivery records nothing and does not crash the tail" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      registry = start_mode_registry([@repo])
      assert %{status: :error} = GithubWebhook.handle_delivery("issue_comment", "not-a-map", repo: @repo, server: registry)

      assert %{status: :error, reason: :missing_repository} =
               GithubWebhook.handle_delivery("issue_comment", Map.delete(issue_comment_delivery(ticket), "repository"),
                 repo: @repo,
                 server: registry
               )

      assert Webhooks.transport(@repo, server: registry) == :polling
    end

    test "the tail is unaffected when no mode registry is running" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(ticket),
                 repo: @repo,
                 server: :no_mode_registry_here
               )
    end
  end
end
