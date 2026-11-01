Code.require_file("../support/decision_store_case.ex", __DIR__)

defmodule Aiur.ClosedDecisionCleanupTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.Orchestrator.WorkspaceCleanup

  test "closing a ticket moots its open human-required decision and retires stale attention", %{dir: dir} do
    parent = self()
    store = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "question" => "May this closed ticket proceed?",
                 "authority" => "human_required",
                 "context" => %{"authority_basis" => "security"},
                 "blocking" => true,
                 "options" => [%{"id" => "yes", "label" => "Yes"}]
               },
               [ticket: %{identifier: "closed-human-42", title: "Closed ticket", url: nil}, source: %{agent_id: "closed-human-test", session_id: "session", event_id: nil}],
               store
             )

    assert {:ok, %{decision: deferred}} =
             request(store, %{"question" => "Should this deferred question remain?", "blocking" => true},
               ticket: %{identifier: "closed-human-42", title: "Closed ticket", url: nil},
               source: %{agent_id: "closed-human-deferred", session_id: "session", event_id: nil}
             )

    assert {:ok, %{decision: deferred}} = DecisionStore.defer(deferred.decision_id, [actor: %{kind: :operator, id: "operator"}], store)

    assert {:ok, %{decision: unrelated}} =
             request(store, %{"question" => "Should this unrelated ticket proceed?", "blocking" => true},
               ticket: %{identifier: "open-human-42", title: "Open ticket", url: nil},
               source: %{agent_id: "open-human", session_id: "session", event_id: nil}
             )

    assert {:ok, %{decision: answered}} =
             request(store, %{"question" => "Already answered?", "blocking" => false, "options" => [%{"id" => "yes", "label" => "Yes"}]},
               ticket: %{identifier: "closed-human-42", title: "Closed ticket", url: nil},
               source: %{agent_id: "closed-human-answered", session_id: "session", event_id: nil}
             )

    assert {:ok, %{decision: answered}} =
             answer(store, answered.decision_id, %{"idempotency_key" => "answered-before-close", "expected_version" => 1, "option_id" => "yes"})

    stale_topic = Aiur.DecisionAttentionSignals.stale_topic(decision)

    assert :ok =
             Aiur.DecisionAttentionSignals.sync_expiry(decision, :stale_blocking, decision.created_at,
               condition_state_fun: fn _topic -> :unknown end,
               alert_fun: fn topic, opts ->
                 send(parent, {:alert, topic, opts})
                 :ok
               end
             )

    assert_receive {:alert, ^stale_topic, initial_opts}, 1_000
    assert Keyword.fetch!(initial_opts, :needs_attention)
    assert :ok = WorkspaceCleanup.start_terminal_workspace_cleanups([{"closed-human-42", :invalid_leaf, nil}], decision_store: store)
    assert_receive {:workspace_cleanup_finished, :invalid_leaf, {:error, _message}}, 10_000

    assert {:ok, %{decision: obsolete}} = DecisionStore.retained_lookup(decision.decision_id, store)
    assert obsolete.decision_status == :moot
    assert obsolete.answer == nil
    assert {:ok, %{decision: obsolete_deferred}} = DecisionStore.retained_lookup(deferred.decision_id, store)
    assert obsolete_deferred.decision_status == :moot
    assert obsolete_deferred.answer == nil
    assert {:ok, %{decision: still_open}} = DecisionStore.retained_lookup(unrelated.decision_id, store)
    assert still_open.decision_status == :open
    assert {:ok, %{decision: still_answered}} = DecisionStore.retained_lookup(answered.decision_id, store)
    assert still_answered.decision_status == :decided
    assert still_answered.answer != nil
    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.any?(audit, &match?(%{type: :decision_mooted, data: %{reason_class: "ticket_closed", detail: detail}} when is_binary(detail), &1))

    assert :ok =
             Aiur.DecisionAttentionSignals.reconcile([obsolete], [], [], decision.created_at,
               condition_state_fun: fn topic -> if topic == stale_topic, do: :firing, else: :unknown end,
               alert_fun: fn topic, opts ->
                 send(parent, {:alert, topic, opts})
                 :ok
               end
             )

    assert_receive {:alert, resolved_topic, resolved_opts}, 1_000
    assert resolved_topic == stale_topic <> ".resolved"
    refute Keyword.fetch!(resolved_opts, :needs_attention)
    refute_receive {:alert, ^stale_topic, _opts}, 50
  end

  test "an unavailable decision store does not stop terminal workspace cleanup" do
    unavailable_store =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Process.exit(unavailable_store, :kill)

    assert :ok = WorkspaceCleanup.start_terminal_workspace_cleanups([{"closed-human-unavailable", :invalid_leaf, nil}], decision_store: unavailable_store)
    assert_receive {:workspace_cleanup_finished, :invalid_leaf, {:error, _message}}, 10_000
  end
end
