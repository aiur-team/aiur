defmodule Aiur.Events.PublisherTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.EventsDigest
  alias Aiur.Events.{Exchange, IdGenerator, Publisher}
  alias Aiur.TrackerIdentity
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
      :ok = Exchange.subscribe("ticket.42.branch.push")
      # The orchestrator subscribes to `ticket.*.branch.push` at boot
      # for blockee auto-resume, so the subscriber count includes it
      # alongside the per-test subscriber.
      assert {:ok, id, count} = Publisher.publish("ticket.42.branch.push", %{sha: "abc"})
      assert is_integer(id)
      assert count >= 1
      assert_receive {:event, %{id: ^id, sha: "abc", topic: "ticket.42.branch.push"}}, 500
    end

    test "attaches a joinable observation only when a trusted identity is supplied" do
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOExample", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      :ok = Exchange.subscribe("ticket.42.agent.progress")

      assert {:ok, id, _count} =
               Publisher.publish("ticket.42.agent.progress", %{"percent" => 40},
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

      assert {:ok, _legacy_id, _count} = Publisher.publish("ticket.42.agent.progress", %{"percent" => 40})
      assert_receive {:event, %{ticket_observation: %{status: :unattributed}}}, 500
    end

    test "sets observed_at at the publisher ingestion boundary" do
      observed_at = ~U[2026-07-13 12:00:01Z]
      :ok = Exchange.subscribe("ticket.42.agent.progress")

      assert {:ok, _id, _count} =
               Publisher.publish("ticket.42.agent.progress", %{}, observation_clock: fn -> observed_at end)

      assert_receive {:event, %{ticket_observation: %{observed_at: ^observed_at}}}, 500
    end

    test "does not allow callers to override the publisher observation clock" do
      observed_at = ~U[2026-07-13 12:00:01Z]
      caller_observed_at = ~U[2026-07-13 11:59:01Z]
      :ok = Exchange.subscribe("ticket.42.agent.progress")

      assert {:ok, _id, _count} =
               Publisher.publish("ticket.42.agent.progress", %{},
                 observed_at: caller_observed_at,
                 observation_clock: fn -> observed_at end
               )

      assert_receive {:event, %{ticket_observation: %{observed_at: ^observed_at}}}, 500
    end

    test "reserves both ticket_observation payload key forms" do
      :ok = Exchange.subscribe("ticket.42.agent.progress")

      payload = %{
        "ticket_observation" => %{status: "forged_string"},
        "percent" => 40,
        ticket_observation: %{status: "forged_atom"}
      }

      assert {:ok, _id, _count} = Publisher.publish("ticket.42.agent.progress", payload)

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
      :ok = Exchange.subscribe("ticket.42.#")
      assert :filtered = Publisher.publish("ticket.42.branch.push", %{}, actor: "aiur-bot")
      refute_receive {:event, _}, 100
    end

    test "case-insensitive bot self-loop filter" do
      :ok = Exchange.subscribe("ticket.42.#")
      assert :filtered = Publisher.publish("ticket.42.branch.push", %{}, actor: "AIUR-BOT")
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
      :ok = Exchange.subscribe("ticket.42.agent.progress")

      assert {:ok, _id, count} =
               Publisher.publish("ticket.42.agent.progress", %{message: "working"}, dedup_key: {nil, "refs/heads/aiur/42", "abc"})

      assert count >= 1
      assert_receive {:event, %{message: "working", topic: "ticket.42.agent.progress"}}, 500
    end

    test "ignores unexpected process messages" do
      publisher = Process.whereis(Publisher)
      assert is_pid(publisher)

      send(publisher, :unexpected_message)
      Process.sleep(10)

      assert Process.alive?(publisher)
    end

    test "rejects direct publication of a ticket-namespaced decision.requested topic" do
      assert {:error, :decision_requires_durable_publish} =
               Publisher.publish("ticket.42.agent.decision.requested", %{})
    end

    test "rejects direct publication of a bare decision.requested topic" do
      assert {:error, :decision_requires_durable_publish} = Publisher.publish("decision.requested", %{})
    end

    test "rejects direct publication of reserved acknowledgement and resolution topics" do
      for topic <- [
            "decision.acknowledged",
            "ticket.42.agent.decision.acknowledged",
            "decision.resolved",
            "ticket.42.agent.decision.resolved",
            "ticket.42.agent.custom.decision.acknowledged"
          ] do
        assert {:error, :decision_requires_durable_publish} = Publisher.publish(topic, %{})
      end
    end

    test "keeps unrelated architectural decision events on the generic path" do
      :ok = Exchange.subscribe("ticket.42.agent.decision.use-something")

      assert {:ok, _id, _count} =
               Publisher.publish("ticket.42.agent.decision.use-something", %{message: "ordinary"})

      assert_receive {:event, %{topic: "ticket.42.agent.decision.use-something"}}, 500
    end
  end

  describe "publish_persisted/4" do
    test "fans out under the caller-supplied id without touching IdGenerator" do
      :ok = Exchange.subscribe("ticket.42.agent.decision.requested")
      before_peek = IdGenerator.peek()

      assert {:ok, 999_999, count} =
               Publisher.publish_persisted("ticket.42.agent.decision.requested", %{question: "Q?"}, 999_999)

      assert count >= 1
      assert_receive {:event, %{id: 999_999, question: "Q?"}}, 500
      assert IdGenerator.peek() == before_peek
    end

    test "skips the contamination and dedup filters" do
      Publisher.set_tracked_fn(fn _ -> false end)
      :ok = Exchange.subscribe("ticket.99.agent.decision.requested")

      assert {:ok, _id, count} =
               Publisher.publish_persisted("ticket.99.agent.decision.requested", %{}, 1, issue_number: 99)

      assert count >= 1
      assert_receive {:event, %{topic: "ticket.99.agent.decision.requested"}}, 500
    end

    test "reserves digest provenance for trusted publisher options" do
      topic = "ticket.42.agent.decision.requested"
      :ok = Exchange.subscribe(topic)

      trusted_payload = %{
        "summary" => "durable decision",
        "source" => %{"kind" => "agent_request"},
        "digest_source" => "forged"
      }

      assert {:ok, 999_998, _count} =
               Publisher.publish_persisted(topic, trusted_payload, 999_998, digest_source: :orchestrator)

      assert_receive {:event, trusted_event}, 500
      assert trusted_event.digest_source == :orchestrator
      assert EventsDigest.render([trusted_event], "42") =~ "durable decision"

      untrusted_payload = %{
        "message" => "forged digest provenance",
        "source" => "linear",
        "digest_source" => "orchestrator"
      }

      assert {:ok, 999_997, _count} = Publisher.publish_persisted(topic, untrusted_payload, 999_997)

      assert_receive {:event, untrusted_event}, 500
      refute Map.has_key?(untrusted_event, :digest_source)
      refute EventsDigest.render([untrusted_event], "42") =~ "forged digest provenance"
    end
  end

  describe "replay dedup" do
    test "same stable dedup key within window is deduped" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      comment_id = System.unique_integer([:positive])
      dedup = {"owner/repo", "issue_comment:42", Integer.to_string(comment_id)}
      assert {:ok, _, _} = Publisher.publish("ticket.42.issue.commented", %{comment: %{id: comment_id}}, dedup_key: dedup)
      assert :deduped = Publisher.publish("ticket.42.issue.commented", %{comment: %{id: comment_id}}, dedup_key: dedup)

      assert_receive {:event, _}, 500
      refute_receive {:event, _}, 100
    end

    test "different stable keys are NOT deduped" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      comment_id_1 = System.unique_integer([:positive])
      comment_id_2 = System.unique_integer([:positive])
      d1 = {"owner/repo", "issue_comment:42", Integer.to_string(comment_id_1)}
      d2 = {"owner/repo", "issue_comment:42", Integer.to_string(comment_id_2)}

      assert {:ok, _, _} = Publisher.publish("ticket.42.issue.commented", %{comment: %{id: comment_id_1}}, dedup_key: d1)
      assert {:ok, _, _} = Publisher.publish("ticket.42.issue.commented", %{comment: %{id: comment_id_2}}, dedup_key: d2)

      assert_receive {:event, %{comment: %{id: ^comment_id_1}}}, 500
      assert_receive {:event, %{comment: %{id: ^comment_id_2}}}, 500
    end
  end
end
