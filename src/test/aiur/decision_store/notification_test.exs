Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.NotificationTest do
  use Aiur.DecisionStoreCase, async: false

  describe "notification" do
    test "an accepted request fans out through Exchange under its reserved event id and broadcasts on PubSub",
         %{dir: dir} do
      pid = start_store!(dir)
      :ok = Exchange.subscribe("ticket.979.agent.decision.requested")
      :ok = Exchange.subscribe("executor.decision.requested")
      :ok = DecisionPubSub.subscribe()

      source_id = "notification-#{System.unique_integer([:positive])}"
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => source_id}
      assert {:ok, %{status: :accepted, decision: decision}} = request(pid, payload)
      decision_id = decision.decision_id

      assert_receive {:event,
                      %{
                        "question" => "Deploy now?",
                        "decision_id" => ^decision_id,
                        topic: "ticket.979.agent.decision.requested",
                        digest_source: :orchestrator,
                        id: cursor_event_id
                      } = request_event},
                     500

      assert cursor_event_id > 0
      assert EventsDigest.render([request_event], "979") =~ "ticket.979.agent.decision.requested"

      assert_receive {:event,
                      %{
                        topic: "executor.decision.requested",
                        decision_id: ^decision_id,
                        decision_version: 1,
                        issue_identifier: "979",
                        provenance: :decision_store
                      }},
                     500

      [persisted] =
        dir
        |> Path.join("decisions.ndjson")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert persisted["event_id"] == "decision-provenance-v1:" <> Integer.to_string(cursor_event_id)
      assert_receive {:decision_changed, ^decision_id, 1}, 500
    end

    test "a duplicate does not fan out again", %{dir: dir} do
      pid = start_store!(dir)
      source_id = "notification-duplicate-#{System.unique_integer([:positive])}"
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => source_id}
      assert {:ok, %{decision: decision}} = request(pid, payload)
      decision_id = decision.decision_id

      :ok = Exchange.subscribe("ticket.979.agent.decision.requested")
      :ok = Exchange.subscribe("executor.decision.requested")
      assert {:ok, %{status: :duplicate, decision: %{decision_id: ^decision_id}}} = request(pid, payload)
      refute_receive {:event, %{"decision_id" => ^decision_id, topic: "ticket.979.agent.decision.requested"}}, 200
      refute_receive {:event, %{decision_id: ^decision_id, topic: "executor.decision.requested"}}, 200
    end

    test "retries a failed requested notification from the canonical Decision", %{dir: dir} do
      parent = self()

      publisher = fn decision ->
        send(parent, {:publish_failed, decision.decision_id, decision.version})
        {:error, :journal_unavailable}
      end

      reconciler = fn decision ->
        send(parent, {:reconciled, decision.decision_id, decision.version})
        {:ok, 1788, 1}
      end

      scheduler = fn server, message, _delay ->
        send(parent, {:retry_scheduled, server, message})
        make_ref()
      end

      pid =
        start_store!(dir,
          executor_request_publisher: publisher,
          executor_request_reconciler: reconciler,
          dispatch_scheduler: scheduler
        )

      assert {:ok, %{decision: decision}} =
               request(pid, %{"question" => "Recover this Command?", "blocking" => true})

      assert_receive {:publish_failed, decision_id, 1}, 1000
      assert decision_id == decision.decision_id

      assert_receive {:retry_scheduled, ^pid, {:retry_executor_request_notification, ^decision_id, 1, 1} = retry_message}, 1000

      send(pid, retry_message)
      assert_receive {:reconciled, ^decision_id, 1}, 1000
    end

    test "an accepted expiration fans out on the owning ticket's decision.expired topic", %{dir: dir} do
      pid = start_store!(dir)
      :ok = Exchange.subscribe("ticket.979.agent.decision.expired")

      assert {:ok, %{decision: decision}} =
               request(pid, %{"question" => "Still waiting?", "blocking" => true})

      assert {:ok, %{status: :accepted}} =
               DecisionStore.expire(decision.decision_id, "agent_not_running", [], pid)

      decision_id = decision.decision_id

      assert_receive {:event,
                      %{
                        "event_type" => "decision_expired",
                        "decision_id" => ^decision_id,
                        "decision_version" => 1,
                        "data" => %{"reason_class" => "agent_not_running"},
                        topic: "ticket.979.agent.decision.expired",
                        digest_source: :orchestrator
                      } = expired_event},
                     500

      assert EventsDigest.render([expired_event], "979") =~ "ticket.979.agent.decision.expired"
    end
  end
end
