defmodule Aiur.Events.PublisherTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.TrackerIdentity
  alias Aiur.Webhooks
  alias Aiur.Webhooks.ModeRegistry
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_bot_account: "aiur-bot"
    )

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end

      # Reset tracked_fn to default (accept all)
      Publisher.set_tracked_fn(fn _ -> true end)
    end)

    :ok
  end

  describe "publish/3" do
    test "publishes a happy-path event for a tracked issue" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.branch.push"
      :ok = Exchange.subscribe(ticket_topic)
      # The orchestrator subscribes to `ticket.*.branch.push` at boot
      # for blockee auto-resume, so the subscriber count includes it
      # alongside the per-test subscriber.
      assert {:ok, id, count} = Publisher.publish(ticket_topic, %{sha: "abc"})
      assert is_integer(id)
      assert count >= 1
      assert_receive {:event, %{id: ^id, sha: "abc", topic: ^ticket_topic}}, 500
    end

    test "attaches a joinable observation only when a trusted identity is supplied" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.agent.progress"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOExample", "number" => String.to_integer(ticket)},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      :ok = Exchange.subscribe(ticket_topic)

      assert {:ok, id, _count} =
               Publisher.publish(ticket_topic, %{"percent" => 40},
                 identity: identity,
                 observation_source: %{kind: :agent_event, name: "progress"},
                 observation_provenance: %{run_id: "run-1", session_id: "session-1"},
                 occurred_at: "2026-07-13T12:00:00Z",
                 observed_at: "2026-07-13T12:00:01Z"
               )

      assert_receive {:event, %{id: ^id, ticket_observation: observation}}, 500
      assert observation.status == :joinable
      assert observation.tracker_identity == identity
      assert observation.attributes == %{percent: 40}

      assert {:ok, _legacy_id, _count} = Publisher.publish(ticket_topic, %{"percent" => 40})
      assert_receive {:event, %{ticket_observation: %{status: :unattributed}}}, 500
    end

    test "sets observed_at at the publisher ingestion boundary" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.agent.progress"
      observed_at = ~U[2026-07-13 12:00:01Z]
      :ok = Exchange.subscribe(ticket_topic)

      assert {:ok, _id, _count} =
               Publisher.publish(ticket_topic, %{}, observation_clock: fn -> observed_at end)

      assert_receive {:event, %{ticket_observation: %{observed_at: ^observed_at}}}, 500
    end

    test "does not allow callers to override the publisher observation clock" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.agent.progress"
      observed_at = ~U[2026-07-13 12:00:01Z]
      caller_observed_at = ~U[2026-07-13 11:59:01Z]
      :ok = Exchange.subscribe(ticket_topic)

      assert {:ok, _id, _count} =
               Publisher.publish(ticket_topic, %{},
                 observed_at: caller_observed_at,
                 observation_clock: fn -> observed_at end
               )

      assert_receive {:event, %{ticket_observation: %{observed_at: ^observed_at}}}, 500
    end

    test "reserves both ticket_observation payload key forms" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.agent.progress"
      :ok = Exchange.subscribe(ticket_topic)

      payload = %{
        "ticket_observation" => %{status: "forged_string"},
        "percent" => 40,
        ticket_observation: %{status: "forged_atom"}
      }

      assert {:ok, _id, _count} = Publisher.publish(ticket_topic, payload)

      assert_receive {:event, event}, 500
      refute Map.has_key?(event, "ticket_observation")
      assert event.ticket_observation.status == :unattributed

      encoded = Jason.encode!(event)
      decoded = Jason.decode!(encoded)
      assert decoded["ticket_observation"]["status"] == "unattributed"
      refute encoded =~ "forged_atom"
      refute encoded =~ "forged_string"
    end

    test "drops events whose actor is the bot_account" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.#"
      ticket_topic1 = "ticket.#{ticket}.branch.push"
      :ok = Exchange.subscribe(ticket_topic)
      assert :filtered = Publisher.publish(ticket_topic1, %{}, actor: "aiur-bot")
      refute_receive {:event, %{topic: ^ticket_topic1}}, 100
    end

    test "case-insensitive bot self-loop filter" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.#"
      ticket_topic1 = "ticket.#{ticket}.branch.push"
      :ok = Exchange.subscribe(ticket_topic)
      assert :filtered = Publisher.publish(ticket_topic1, %{}, actor: "AIUR-BOT")
    end

    test "drops events for untracked issues" do
      Publisher.set_tracked_fn(fn n -> n == 42 end)

      :ok = Exchange.subscribe("ticket.99.#")
      assert :filtered = Publisher.publish("ticket.99.branch.push", %{}, issue_number: 99)
      refute_receive {:event, _}, 100
    end

    test "allows events with nil issue_number (system topics)" do
      :ok = Exchange.subscribe("system.main.branch.push")
      assert {:ok, _id, count} = Publisher.publish("system.main.branch.push", %{sha: "abc"})
      assert count >= 1
      assert_receive {:event, _}, 500
    end

    test "bypass_contamination skips the tracked filter for untracked issues" do
      # A :deactivated ticket is intentionally absent from the tracked set,
      # but an inbound human comment must still reach the orchestrator to
      # reactivate it. bypass_contamination lets it through.
      Publisher.set_tracked_fn(fn n -> n == 42 end)

      :ok = Exchange.subscribe("ticket.99.issue.commented")

      assert {:ok, _id, count} =
               Publisher.publish("ticket.99.issue.commented", %{comment: %{}},
                 issue_number: 99,
                 bypass_contamination: true
               )

      assert count >= 1
      assert_receive {:event, %{topic: "ticket.99.issue.commented"}}, 500
    end

    test "bypass_contamination still drops bot self-loop comments" do
      # bot_account is "aiur-bot" (set in the workflow file at setup).
      assert :filtered =
               Publisher.publish("ticket.99.issue.commented", %{comment: %{}},
                 issue_number: 99,
                 bypass_contamination: true,
                 actor: "aiur-bot"
               )
    end

    test "malformed dedup keys do not block publishing" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.agent.progress"
      :ok = Exchange.subscribe(ticket_topic)

      assert {:ok, _id, count} =
               Publisher.publish(ticket_topic, %{message: "working"}, dedup_key: {nil, "refs/heads/aiur/#{ticket}", "abc"})

      assert count >= 1
      assert_receive {:event, %{message: "working", topic: ^ticket_topic}}, 500
    end

    test "ignores unexpected process messages" do
      publisher = Process.whereis(Publisher)
      assert is_pid(publisher)

      send(publisher, :unexpected_message)
      Process.sleep(10)

      assert Process.alive?(publisher)
    end

    test "rejects direct publication of a ticket-namespaced decision.requested topic" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.agent.decision.requested"

      assert {:error, :decision_requires_durable_publish} =
               Publisher.publish(ticket_topic, %{})
    end

    test "rejects direct publication of a bare decision.requested topic" do
      assert {:error, :decision_requires_durable_publish} = Publisher.publish("decision.requested", %{})
    end

    test "rejects direct publication of reserved acknowledgement and resolution topics" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.agent.decision.acknowledged"
      ticket_topic1 = "ticket.#{ticket}.agent.decision.resolved"
      ticket_topic2 = "ticket.#{ticket}.agent.custom.decision.acknowledged"

      for topic <- [
            "decision.acknowledged",
            ticket_topic,
            "decision.resolved",
            ticket_topic1,
            ticket_topic2
          ] do
        assert {:error, :decision_requires_durable_publish} = Publisher.publish(topic, %{})
      end
    end

    test "keeps unrelated architectural decision events on the generic path" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.agent.decision.use-something"
      :ok = Exchange.subscribe(ticket_topic)

      assert {:ok, _id, _count} =
               Publisher.publish(ticket_topic, %{message: "ordinary"})

      assert_receive {:event, %{topic: ^ticket_topic}}, 500
    end

    test "rejects GitHub-sourced events in the internal executor namespace" do
      assert {:error, :executor_namespace_rejects_github_source} =
               Publisher.publish("executor.notify.untrusted", %{message: "external"}, source: :github)

      assert {:error, :executor_namespace_rejects_github_source} =
               Publisher.publish("executor.decision.deferred", %{message: "external"}, observation_source: %{kind: :github})
    end
  end

  describe "replay dedup" do
    test "same stable dedup key within window is deduped" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(ticket_topic)

      comment_id = System.unique_integer([:positive])
      dedup = {"owner/repo", "issue_comment:#{ticket}", Integer.to_string(comment_id)}
      assert {:ok, _, _} = Publisher.publish(ticket_topic, %{comment: %{id: comment_id}}, dedup_key: dedup)
      assert :deduped = Publisher.publish(ticket_topic, %{comment: %{id: comment_id}}, dedup_key: dedup)

      assert_receive {:event, _}, 500
      refute_receive {:event, _}, 100
    end

    test "different stable keys are NOT deduped" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(ticket_topic)

      comment_id_1 = System.unique_integer([:positive])
      comment_id_2 = System.unique_integer([:positive])
      d1 = {"owner/repo", "issue_comment:#{ticket}", Integer.to_string(comment_id_1)}
      d2 = {"owner/repo", "issue_comment:#{ticket}", Integer.to_string(comment_id_2)}

      assert {:ok, _, _} = Publisher.publish(ticket_topic, %{comment: %{id: comment_id_1}}, dedup_key: d1)
      assert {:ok, _, _} = Publisher.publish(ticket_topic, %{comment: %{id: comment_id_2}}, dedup_key: d2)

      assert_receive {:event, %{comment: %{id: ^comment_id_1}}}, 500
      assert_receive {:event, %{comment: %{id: ^comment_id_2}}}, 500
    end
  end

  # A poll-sourced publish reaching the bus means the dedup gates let it
  # through, so no webhook had already delivered that event. That is the
  # corroboration `Aiur.Webhooks.DeliveryMode` degrades on — without this
  # wiring the silence sweep has no evidence and can never degrade a repo, and
  # with it firing on the wrong pipe every healthy fleet degrades itself.
  describe "webhook activity corroboration" do
    # Activity corroborates an existing mode and never mints one, so the repo
    # has to carry a webhook expectation before any of this is observable —
    # which is also the only state in which the corroboration matters.
    setup do
      {:ok, _mode} = ModeRegistry.configure("owner/repo", true)
      :ok
    end

    defp resource_for(id), do: ResourceStore.key_for_repo(:issue_comment, "owner/repo", id)

    test "a poll-sourced GitHub publish records repository activity" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      comment_id = System.unique_integer([:positive])

      assert {:ok, _id, _count} =
               Publisher.publish(ticket_topic, %{comment: %{id: comment_id}},
                 resource: resource_for(comment_id),
                 resource_source: :poll
               )

      assert %DateTime{} = Webhooks.mode("owner/repo").last_activity_at
    end

    test "a webhook-sourced publish records no activity" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      comment_id = System.unique_integer([:positive])
      before = Webhooks.mode("owner/repo").last_activity_at

      assert {:ok, _id, _count} =
               Publisher.publish(ticket_topic, %{comment: %{id: comment_id}},
                 resource: resource_for(comment_id),
                 resource_source: :webhook
               )

      assert Webhooks.mode("owner/repo").last_activity_at == before,
             "the webhook pipe proving itself silent would degrade every healthy repo"
    end

    test "a publish carrying no GitHub resource records no activity" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.branch.push"
      before = Webhooks.mode("owner/repo").last_activity_at

      assert {:ok, _id, _count} = Publisher.publish(ticket_topic, %{sha: "abc"})

      assert Webhooks.mode("owner/repo").last_activity_at == before
    end

    test "a GitHub resource requires an explicit source" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      comment_id = System.unique_integer([:positive])

      assert_raise KeyError, fn ->
        Publisher.publish(ticket_topic, %{comment: %{id: comment_id}}, resource: resource_for(comment_id))
      end
    end

    test "an event filtered as a bot self-loop still records the observation" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      comment_id = System.unique_integer([:positive])
      before = Webhooks.mode("owner/repo").last_activity_at

      assert :filtered =
               Publisher.publish(ticket_topic, %{comment: %{id: comment_id}},
                 resource: resource_for(comment_id),
                 resource_source: :poll,
                 actor: "aiur-bot"
               )

      refute Webhooks.mode("owner/repo").last_activity_at == before,
             "this fleet's traffic is mostly agent-authored, so ignoring filtered events would let ingress die with no corroboration and no alert"
    end

    # The poller is publish-and-reject and re-offers old resources every sweep
    # (rewound watermark, 304 list republish, cursorless review threads). If a
    # re-observation counted, `last_activity_at` would march forward on a repo
    # where nothing happened and degrade a healthy webhook after one threshold.
    test "a deduped re-publish of the same resource records no activity" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      comment_id = System.unique_integer([:positive])
      resource = resource_for(comment_id)
      opts = [resource: resource, resource_source: :poll, resource_version: "v1"]

      assert {:ok, _id, _count} = Publisher.publish(ticket_topic, %{comment: %{id: comment_id}}, opts)

      settled = Webhooks.mode("owner/repo").last_activity_at

      assert :deduped = Publisher.publish(ticket_topic, %{comment: %{id: comment_id}}, opts)

      assert Webhooks.mode("owner/repo").last_activity_at == settled,
             "re-observing an already-processed resource is not evidence that a delivery was owed"
    end

    # Pins the `:deduped` guard on its own. The dedup window catches this
    # replay while the store has never seen the resource, so the
    # already-processed check cannot cover it and only the outcome can.
    test "a replay caught by the dedup window records no activity even when the resource is novel" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      dedup_key = {"owner/repo", "issue_comment:#{ticket}", Integer.to_string(System.unique_integer([:positive]))}
      first_id = System.unique_integer([:positive])
      second_id = System.unique_integer([:positive])

      assert {:ok, _id, _count} =
               Publisher.publish(ticket_topic, %{comment: %{id: first_id}},
                 resource: resource_for(first_id),
                 resource_source: :poll,
                 dedup_key: dedup_key
               )

      settled = Webhooks.mode("owner/repo").last_activity_at

      assert :deduped =
               Publisher.publish(ticket_topic, %{comment: %{id: second_id}},
                 resource: resource_for(second_id),
                 resource_source: :poll,
                 dedup_key: dedup_key
               )

      assert Webhooks.mode("owner/repo").last_activity_at == settled
    end

    # The production shape: a filterable comment is filterable on its *first*
    # sight, so it is never published, never marked processed, and never enters
    # the dedup window. The poller then re-offers it every cycle forever via
    # the 304 list republish and the rewound watermark.
    test "re-observing a bot comment that was filtered on first sight records no further activity" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      comment_id = System.unique_integer([:positive])

      opts = [
        resource: resource_for(comment_id),
        resource_source: :poll,
        actor: "aiur-bot"
      ]

      assert :filtered = Publisher.publish(ticket_topic, %{comment: %{id: comment_id}}, opts)

      settled = Webhooks.mode("owner/repo").last_activity_at

      assert :filtered = Publisher.publish(ticket_topic, %{comment: %{id: comment_id}}, opts)

      assert Webhooks.mode("owner/repo").last_activity_at == settled,
             "the same comment re-offered every sweep is one event, not new evidence, or an idle repo degrades a healthy webhook"
    end

    test "re-observing an untracked-issue comment filtered on first sight records no further activity" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      comment_id = System.unique_integer([:positive])
      Publisher.set_tracked_fn(fn _issue -> false end)

      opts = [
        resource: resource_for(comment_id),
        resource_source: :poll,
        issue_number: String.to_integer(ticket)
      ]

      assert :filtered = Publisher.publish(ticket_topic, %{comment: %{id: comment_id}}, opts)

      settled = Webhooks.mode("owner/repo").last_activity_at

      assert :filtered = Publisher.publish(ticket_topic, %{comment: %{id: comment_id}}, opts)

      assert Webhooks.mode("owner/repo").last_activity_at == settled
    end

    test "an event filtered as an untracked issue still records the observation" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      comment_id = System.unique_integer([:positive])
      Publisher.set_tracked_fn(fn _issue -> false end)
      before = Webhooks.mode("owner/repo").last_activity_at

      assert :filtered =
               Publisher.publish(ticket_topic, %{comment: %{id: comment_id}},
                 resource: resource_for(comment_id),
                 resource_source: :poll,
                 issue_number: String.to_integer(ticket)
               )

      refute Webhooks.mode("owner/repo").last_activity_at == before
    end
  end
end
