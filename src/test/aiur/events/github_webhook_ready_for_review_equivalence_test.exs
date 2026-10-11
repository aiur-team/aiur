defmodule Aiur.Events.GithubWebhookReadyForReviewEquivalenceTest do
  @moduledoc """
  `ready_for_review` is one wake whether a delivery or the poll observes it.

  Split out of `github_webhook_equivalence_test.exs`, whose moduledoc states
  what equivalence means here.
  """

  use Aiur.TestSupport.WebhookEquivalenceFixture

  alias Aiur.Events.{Exchange, GithubWebhook}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Orchestrator.{ReadyForReviewTransitions, State}

  @repo "owner/repo"

  test "pull request ready for review publishes its own topic" do
    :ok = Exchange.subscribe("ticket.55.pr.ready_for_review")
    last_review_sha = String.duplicate("c", 40)
    review_key = ResourceStore.key_for_repo(:pull_request_reviews, @repo, 901)
    :ok = ResourceStore.put_resource(review_key, [%{"submitted_at" => "2026-06-24T11:00:00Z", "commit_id" => last_review_sha}], source: :poll)

    delivery = %{
      "action" => "ready_for_review",
      "repository" => %{"full_name" => @repo},
      "pull_request" => %{
        "number" => 901,
        "draft" => false,
        "updated_at" => "2026-06-24T12:00:00Z",
        "head" => %{"ref" => "aiur/55", "sha" => "deadbeef"}
      },
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: ["ticket.55.pr.ready_for_review"]} =
             GithubWebhook.handle_delivery("pull_request", delivery, repo: @repo, orchestrator: self())

    assert %{topic: "ticket.55.pr.ready_for_review", action: "ready_for_review", pr: %{"number" => 901, "draft" => false, "last_review_sha" => ^last_review_sha}} =
             await_event("ticket.55.pr.ready_for_review")

    assert_receive {:github_pr_ready_transition, "55", 901, "deadbeef"}, 500
  end

  # #2707: on a poll-only repository nothing delivers `ready_for_review`, and
  # the Events API does not carry it. An agent runs `gh pr ready` while its
  # ticket is `in-progress`, so the comment poll (which reads every running
  # ticket's PR) is usually the poll that sees the draft flag change. The
  # decision rests on the durable ledger, so a restart neither loses nor
  # repeats the wake.
  describe "poll-side ready_for_review (#2707)" do
    setup do
      previous = Application.get_env(:aiur, :pr_ready_ledger_path)
      path = Path.join(System.tmp_dir!(), "pr-ready-ledger-#{System.unique_integer([:positive])}.json")
      Application.put_env(:aiur, :pr_ready_ledger_path, path)

      on_exit(fn ->
        File.rm(path)
        restore_app_env(:pr_ready_ledger_path, previous)
      end)

      :ok
    end

    test "a PR the agent marks ready publishes ready_for_review once per head" do
      topic = "ticket.57.pr.ready_for_review"
      :ok = Exchange.subscribe(topic)

      state =
        %State{}
        |> poll_draft_flag("57", 902, "draft-head", true)
        |> poll_draft_flag("57", 902, "ready-head", false)

      assert %{
               topic: ^topic,
               action: "ready_for_review",
               pr: %{"number" => 902, "draft" => false, "head" => %{"sha" => "ready-head"}}
             } = event = await_event(topic)

      refute Map.has_key?(event, :observation)

      refute_receive {:event, %{topic: ^topic}}, 100

      # A repeated poll of the same ready PR is not a transition, and a known
      # PR never costs a history read.
      _state = poll_draft_flag(state, "57", 902, "ready-head", false)
      refute_receive {:event, %{topic: ^topic}}, 100
      refute_received {:history_read, _url}
    end

    test "a webhook ready transition seeds the ledger and prevents its initial-sync replay" do
      topic = "ticket.64.pr.ready_for_review"
      :ok = Exchange.subscribe(topic)

      delivery = %{
        "action" => "ready_for_review",
        "repository" => %{"full_name" => @repo},
        "pull_request" => %{
          "number" => 911,
          "draft" => false,
          "head" => %{"ref" => "aiur/64", "sha" => "reviewed-head"}
        },
        "sender" => %{"login" => "its-everdred"}
      }

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("pull_request", delivery, repo: @repo, orchestrator: self())

      assert %{topic: ^topic} = await_event(topic)
      assert_receive {:github_pr_ready_transition, "64", 911, "reviewed-head"}, 500
      assert {:noreply, state} = Aiur.Orchestrator.handle_info({:github_pr_ready_transition, "64", 911, "reviewed-head"}, %State{})
      assert state.pr_ready_ledger[{"64", 911}] == {:announced, "reviewed-head"}

      clear_replay_window()
      _state = poll_draft_flag(state, "64", 911, "reviewed-head", false, [%{"event" => "ready_for_review"}])

      refute_received {:history_read, _url}
      refute_receive {:event, %{topic: ^topic}}, 100
    end

    test "a new ready head after a reviewed head publishes once with both SHAs" do
      topic = "ticket.65.pr.ready_for_review"
      :ok = Exchange.subscribe(topic)
      old_head = String.duplicate("a", 40)
      new_head = String.duplicate("b", 40)
      key = ResourceStore.key_for_repo(:pull_request_reviews, @repo, 912)

      :ok =
        ResourceStore.put_resource(
          key,
          [
            %{"id" => 1, "submitted_at" => "2026-10-10T06:17:00Z", "commit_id" => old_head}
          ],
          source: :poll
        )

      state =
        %State{}
        |> poll_draft_flag("65", 912, old_head, true)
        |> poll_draft_flag("65", 912, old_head, false)

      first = await_event(topic)
      assert get_in(first, [:pr, "last_review_sha"]) == old_head

      state = poll_draft_flag(state, "65", 912, new_head, false)
      second = await_event(topic)

      assert get_in(second, [:pr, "head", "sha"]) == new_head
      assert get_in(second, [:pr, "last_review_sha"]) == old_head
      refute_receive {:event, %{topic: ^topic}}, 100

      _state = poll_draft_flag(state, "65", 912, new_head, false)
      refute_receive {:event, %{topic: ^topic}}, 100
    end

    test "webhook plus poll of the same draft-to-ready transition wakes once" do
      topic = "ticket.58.pr.ready_for_review"
      :ok = Exchange.subscribe(topic)

      state = poll_draft_flag(%State{}, "58", 903, "shared-head", true)

      delivery = %{
        "action" => "ready_for_review",
        "repository" => %{"full_name" => @repo},
        "pull_request" => %{
          "number" => 903,
          "draft" => false,
          "updated_at" => "2026-06-24T12:00:00Z",
          "head" => %{"ref" => "aiur/58", "sha" => "shared-head"}
        },
        "sender" => %{"login" => "its-applekid"}
      }

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("pull_request", delivery, repo: @repo)

      assert %{topic: ^topic} = await_event(topic)

      # The poll then sees the same transition. It shares the webhook's dedup
      # key, so the consumer is not woken twice.
      _state = poll_draft_flag(state, "58", 903, "shared-head", false)
      refute_receive {:event, %{topic: ^topic}}, 100
    end

    # Khala PR #62: the PR went ready while the daemon restarted, so the new
    # daemon's first poll saw it already ready.
    test "a PR that goes ready across a restart publishes once, and not again after another restart" do
      topic = "ticket.59.pr.ready_for_review"
      :ok = Exchange.subscribe(topic)

      _before_restart = poll_draft_flag(%State{}, "59", 904, "draft-head", true)

      after_restart = poll_draft_flag(%State{}, "59", 904, "ready-head", false)
      assert %{pr: %{"number" => 904, "head" => %{"sha" => "ready-head"}}} = await_event(topic)
      refute_receive {:event, %{topic: ^topic}}, 100

      _same_daemon = poll_draft_flag(after_restart, "59", 904, "ready-head", false)
      clear_replay_window()
      _next_restart = poll_draft_flag(%State{}, "59", 904, "ready-head", false)
      refute_receive {:event, %{topic: ^topic}}, 100
      refute_received {:history_read, _url}
    end

    test "a PR first seen ready that was a draft publishes once" do
      topic = "ticket.60.pr.ready_for_review"
      :ok = Exchange.subscribe(topic)

      history = [%{"event" => "labeled"}, %{"event" => "ready_for_review"}]
      state = poll_draft_flag(%State{}, "60", 905, "ready-head", false, history)

      assert_received {:history_read, url}
      assert url =~ "/repos/owner/repo/issues/905/events"
      assert %{observation: "initial_sync", pr: %{"number" => 905, "head" => %{"sha" => "ready-head"}}} = await_event(topic)

      assert state.pr_ready_ledger[{"60", 905}] == {:announced, "ready-head"}
      clear_replay_window()
      _after_restart = poll_draft_flag(%State{}, "60", 905, "ready-head", false, history)
      refute_receive {:event, %{topic: ^topic}}, 100
      refute_received {:history_read, _url}
    end

    # The comment poll folds an observation read when its task started. A
    # stale draft reading folded after the PR was announced must not re-arm
    # the same head, or the next ready poll announces it again.
    test "a stale draft reading after the announcement does not re-announce the same head" do
      topic = "ticket.62.pr.ready_for_review"
      :ok = Exchange.subscribe(topic)

      announced =
        %State{}
        |> poll_draft_flag("62", 907, "ready-head", true)
        |> poll_draft_flag("62", 907, "ready-head", false)

      assert %{pr: %{"number" => 907}} = await_event(topic)

      stale = poll_draft_flag(announced, "62", 907, "ready-head", true)
      assert stale.pr_ready_ledger[{"62", 907}] == {:announced, "ready-head"}

      clear_replay_window()
      _state = poll_draft_flag(stale, "62", 907, "ready-head", false)
      refute_receive {:event, %{topic: ^topic}}, 100
    end

    test "a failed history read is not retried on every poll" do
      topic = "ticket.63.pr.ready_for_review"
      :ok = Exchange.subscribe(topic)

      state = poll_draft_flag(%State{}, "63", 908, "ready-head", false, {:status, 404})
      assert_received {:history_read, _url}
      refute_receive {:event, %{topic: ^topic}}, 100

      state = poll_draft_flag(state, "63", 908, "ready-head", false, {:status, 404})
      refute_received {:history_read, _url}

      # The backoff expires: the read is due again.
      assert {:history_failed, retry_at_ms} = state.pr_ready_ledger[{"63", 908}]

      observation = ReadyForReviewTransitions.observation("63", 908, "ready-head", false)
      refute ReadyForReviewTransitions.needs_history?(state.pr_ready_ledger, observation, retry_at_ms - 1)
      assert ReadyForReviewTransitions.needs_history?(state.pr_ready_ledger, observation, retry_at_ms)
    end

    # The webhook sends only `opened` for a PR opened ready (see the
    # `pull request opened` case above), so the poll publishes nothing either.
    test "a PR opened ready publishes no ready_for_review and reads its history once" do
      topic = "ticket.61.pr.ready_for_review"
      :ok = Exchange.subscribe(topic)

      history = [%{"event" => "labeled"}]
      state = poll_draft_flag(%State{}, "61", 906, "ready-head", false, history)
      assert_received {:history_read, _url}
      refute_receive {:event, %{topic: ^topic}}, 100

      _state = poll_draft_flag(state, "61", 906, "ready-head", false, history)
      refute_receive {:event, %{topic: ^topic}}, 100
      refute_received {:history_read, _url}
    end
  end
end
