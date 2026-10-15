Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.RestartRecoveryTest do
  use Aiur.DecisionStoreCase, async: false

  describe "restart recovery" do
    test "a fresh store instance replays durable state from the same path", %{dir: dir} do
      pid1 = start_store!(dir)
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, %{status: :accepted, decision: accepted}} = request(pid1, payload)
      GenServer.stop(pid1)

      pid2 = start_store!(dir)
      assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, pid2)
      assert replayed.question == accepted.question
      assert replayed.content_hash == accepted.content_hash
      assert DecisionStore.all_history(pid2)[accepted.decision_id] == [replayed]
      assert DecisionStore.health(pid2) == :writable
    end

    test "trusted provenance remains attached to its accepted version after replay", %{dir: dir} do
      pid1 = start_store!(dir)

      provenance = %{
        agent_family: "codex",
        backend: "codex",
        requested_model: "gpt-5.6-terra",
        session_id: "thread-123",
        attempt_id: "attempt-456",
        source: "agent_runner"
      }

      assert {:ok, %{decision: accepted}} =
               request(pid1, %{"question" => "Keep runtime facts?", "blocking" => true}, provenance: provenance)

      GenServer.stop(pid1)
      pid2 = start_store!(dir)

      assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, pid2)
      assert replayed.provenance == accepted.provenance
      assert {:ok, [^replayed]} = DecisionStore.history(accepted.decision_id, pid2)

      assert [history] = DecisionHistory.list(server: pid2, limit: 1)
      assert history.provenance["backend"] == "codex"
      assert history.provenance["session_id"] == "thread-123"
    end

    test "replays trusted provenance and supervisor basis through the full revised lifecycle", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:provenance_lifecycle_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 711}}}
      end

      for confidence <- [0, 50, 100] do
        store_dir = Path.join(dir, "provenance-lifecycle-#{confidence}")
        pid = start_store!(store_dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

        provenance = %{
          agent_family: "codex",
          backend: "codex",
          requested_model: "gpt-5.6-terra",
          resolved_model: "gpt-5.6-terra",
          session_id: "thread-#{confidence}",
          attempt_id: "attempt-#{confidence}",
          source: "agent_runner"
        }

        assert {:ok, %{decision: accepted}} =
                 request(
                   pid,
                   %{
                     "question" => "Apply the approved architecture change?",
                     "blocking" => true,
                     "source_id" => "provenance-lifecycle-#{confidence}",
                     "kind" => "architecture",
                     "authority" => "supervisor_allowed",
                     "reversibility" => "reversible",
                     "options" => [%{"id" => "ship", "label" => "Ship it"}]
                   },
                   provenance: provenance
                 )

        supervisor_opts = [actor: %{kind: :supervisor, id: "supervising-agent"}, supervisor_basis: supervisor_basis(confidence)]

        assert {:ok, %{action: answer}} =
                 answer(
                   pid,
                   accepted.decision_id,
                   %{"idempotency_key" => "provenance-answer-#{confidence}", "expected_version" => 1, "option_id" => "ship"},
                   supervisor_opts
                 )

        assert_receive {:provenance_lifecycle_attempt, _initial_attempt_id}, 1_000
        _queued = wait_for_decision(pid, accepted.decision_id, &(&1.delivery_status == :queued))

        assert {:ok, %{action: revision}} =
                 DecisionStore.revise(
                   accepted.decision_id,
                   %{
                     "idempotency_key" => "provenance-revision-#{confidence}",
                     "expected_version" => 1,
                     "expected_action_id" => answer.action_id,
                     "expected_revision_sequence" => 0,
                     "option_id" => "ship",
                     "rationale" => "Confirmed after the delivery check."
                   },
                   supervisor_opts,
                   pid
                 )

        assert_receive {:provenance_lifecycle_attempt, revision_attempt_id}, 1_000

        _queued =
          wait_for_decision(pid, accepted.decision_id, fn decision ->
            decision.delivery_status == :queued and decision.active_action_id == revision.action_id
          end)

        assert {:ok, :accepted} =
                 DecisionStore.record_delivery(correlated_queue_item(accepted, revision, revision_attempt_id, 711), pid)

        lifecycle_payload = %{
          "decision_id" => accepted.decision_id,
          "action_id" => revision.action_id,
          "expected_version" => 1
        }

        lifecycle_opts = [
          ticket_identifier: "979",
          actor: %{kind: :agent, id: "ticket-agent"},
          source: %{agent_id: "codex", session_id: "session-#{confidence}", invocation_id: "lifecycle-#{confidence}"}
        ]

        assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
                 DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

        assert {:ok, %{status: :accepted, decision_status: :resolved}} =
                 DecisionStore.agent_lifecycle(:resolved, lifecycle_payload, lifecycle_opts, pid)

        GenServer.stop(pid)
        replayed_pid = start_store!(store_dir, dispatch_delay_ms: 60_000)

        assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, replayed_pid)
        assert replayed.provenance == accepted.provenance
        assert replayed.answer.supervisor_basis.confidence == confidence
        assert List.last(replayed.revisions).answer.supervisor_basis.confidence == confidence
        assert replayed.delivery_status == :delivered
        assert replayed.decision_status == :resolved
        assert replayed.acknowledgement.action_id == revision.action_id
        assert replayed.resolution.action_id == revision.action_id

        history = DecisionHistory.list(server: replayed_pid)

        assert Enum.all?(history, &(&1.provenance["backend"] == "codex"))

        assert Enum.any?(history, fn entry ->
                 entry.change == :answered and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.change == :revised and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.dispatch_result == :delivered and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.acknowledgement_result == :acknowledged and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.acknowledgement_result == :resolved and entry.supervisor_basis["confidence"] == confidence
               end)

        limited_history = DecisionHistory.list(server: replayed_pid, limit: 50)

        assert Enum.any?(limited_history, fn entry ->
                 entry.action_id == answer.action_id and entry.dispatch_result == :dispatch_queued and
                   entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(limited_history, fn entry ->
                 entry.action_id == revision.action_id and entry.dispatch_result == :delivered and
                   entry.supervisor_basis["confidence"] == confidence
               end)

        GenServer.stop(replayed_pid)
      end
    end

    test "a decision with an artifact survives restart without being flagged as corrupt", %{dir: dir} do
      pid1 = start_store!(dir)

      payload = %{
        "question" => "Deploy now?",
        "blocking" => true,
        "source_id" => "retry-1",
        "artifacts" => ["https://github.com/its-everdred/aiur"]
      }

      assert {:ok, %{status: :accepted, decision: accepted}} = request(pid1, payload)
      assert [%{kind: :url}] = accepted.artifacts
      GenServer.stop(pid1)

      pid2 = start_store!(dir)
      assert DecisionStore.health(pid2) == :writable
      assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, pid2)
      assert replayed.artifacts == accepted.artifacts
    end
  end
end
