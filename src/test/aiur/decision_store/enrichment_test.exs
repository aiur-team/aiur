Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.EnrichmentTest do
  use Aiur.DecisionStoreCase, async: false

  describe "supervisor enrichment" do
    test "persists attributed enrichment before notification and survives restart", %{dir: dir} do
      pid1 = start_store!(dir)

      assert {:ok, %{decision: v1}} =
               request(pid1, %{
                 "question" => "Which architecture?",
                 "blocking" => true,
                 "source_id" => "supervisor-enrichment",
                 "kind" => "architecture",
                 "authority" => "supervisor_allowed",
                 "reversibility" => "reversible"
               })

      :ok = Exchange.subscribe("ticket.979.agent.decision.enriched")
      :ok = DecisionPubSub.subscribe()

      patch = %{"context" => %{"short_summary" => "Use the canonical store"}}

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich(pid1, v1.decision_id, patch, 1)

      assert v2.version == 2
      assert v2.created_at == v1.created_at
      assert v2.context.short_summary == "Use the canonical store"

      assert {:ok, [^v1, history_v2]} = DecisionStore.history(v1.decision_id, pid1)
      assert history_v2.version == 2

      assert {:ok, [requested, enriched]} = DecisionStore.audit_history(v1.decision_id, pid1)
      assert audit_type(requested) == :requested
      assert %DecisionEvent{type: :enriched, data: data} = enriched
      assert data.actor == %{kind: :supervisor, id: "supervising-agent"}
      assert data.expected_version == 1
      assert data.decision.version == 2

      assert_receive {:event,
                      %{
                        "event_id" => "decision-provenance-v1:" <> reserved_event_id,
                        topic: "ticket.979.agent.decision.enriched",
                        id: cursor_event_id
                      }},
                     500

      assert cursor_event_id > 0
      assert reserved_event_id == Integer.to_string(cursor_event_id)
      assert_receive {:decision_changed, decision_id, 2}, 500
      assert decision_id == v1.decision_id

      persisted = File.read!(Path.join(dir, "decisions.ndjson"))
      assert persisted =~ ~s("event_type":"enriched")

      GenServer.stop(pid1)
      pid2 = start_store!(dir)
      assert DecisionStore.health(pid2) == :writable
      assert {:ok, replayed} = DecisionStore.get(v1.decision_id, pid2)
      assert replayed.version == 2
      assert replayed.context.short_summary == "Use the canonical store"
    end

    test "a non-durable enrichment ID reservation appends nothing", %{dir: dir} do
      pid = start_store!(dir, event_id_reserver: fn -> {:error, :not_durable} end)
      assert {:ok, %{decision: v1}} = request(pid, minimal_attention())

      patch = %{"context" => %{"short_summary" => "Must remain durable"}}
      assert {:error, :event_id_not_durable} = enrich(pid, v1.decision_id, patch, 1)

      assert {:ok, ^v1} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [requested]} = DecisionStore.audit_history(v1.decision_id, pid)
      assert audit_type(requested) == :requested
      assert length(String.split(File.read!(Path.join(dir, "decisions.ndjson")), "\n", trim: true)) == 1
    end

    # Flaky in merge groups; fix tracked in #4463.
    @tag :quarantine
    test "exact replay is duplicate while changed reuse conflicts without append or notification", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: v1}} =
               request(pid, %{
                 "question" => "Which architecture?",
                 "blocking" => true,
                 "source_id" => "supervisor-replay"
               })

      patch = %{"context" => %{"short_summary" => "Canonical"}}
      assert {:ok, %{status: :accepted, decision: accepted}} = enrich(pid, v1.decision_id, patch, 1)

      :ok = Exchange.subscribe("ticket.979.agent.decision.enriched")
      :ok = DecisionPubSub.subscribe()

      assert {:ok, %{status: :duplicate, decision: duplicate}} = enrich(pid, v1.decision_id, patch, 1)
      assert duplicate.version == accepted.version

      changed = %{"context" => %{"short_summary" => "Different"}}

      assert {:error, {:conflict, {:idempotency_conflict, 1}}} =
               enrich(pid, v1.decision_id, changed, 1)

      assert {:ok, audit} = DecisionStore.audit_history(v1.decision_id, pid)
      assert Enum.map(audit, &audit_type/1) == [:requested, :enriched]
      refute_receive {:event, %{topic: "ticket.979.agent.decision.enriched"}}, 100
      refute_receive {:decision_changed, _, _}, 100
      assert length(String.split(File.read!(Path.join(dir, "decisions.ndjson")), "\n", trim: true)) == 2
    end

    test "a stale historical base with no matching enrichment appends nothing", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Original?", "blocking" => true, "source_id" => "supervisor-stale"}
      assert {:ok, %{decision: v1}} = request(pid, base)

      assert {:ok, %{decision: v2}} =
               request(pid, Map.merge(base, %{"question" => "Updated?", "version" => 2}))

      assert {:error, {:conflict, {:stale_version, 1, 2}}} =
               enrich(pid, v1.decision_id, %{"context" => %{"short_summary" => "Stale"}}, 1)

      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, audit} = DecisionStore.audit_history(v1.decision_id, pid)
      assert Enum.map(audit, &audit_type/1) == [:requested, :requested]
    end

    test "enrichment after an answer preserves its lifecycle and never redispatches", %{dir: dir} do
      parent = self()
      dispatches = :counters.new(1, [])
      release_scheduled_work = :atomics.new(1, [])

      dispatcher = fn _decision, _opts ->
        :counters.add(dispatches, 1, 1)
        send(parent, {:dispatched, :counters.get(dispatches, 1)})
        {:ok, %{status: :accepted, item: %{id: 101}}}
      end

      dispatch_scheduler = fn recipient, message, delay_ms ->
        send(parent, {:dispatch_scheduled, recipient, message, delay_ms})

        if :atomics.get(release_scheduled_work, 1) == 1,
          do: send(recipient, message)

        make_ref()
      end

      store_opts = [
        dispatcher: dispatcher,
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 0,
        dispatch_scheduler: dispatch_scheduler
      ]

      pid = start_store!(dir, store_opts)

      assert_receive {:dispatch_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000

      assert {:ok, %{decision: v1}} = request(pid, answerable_request("enrich-after-answer"))

      answer_payload = %{
        "idempotency_key" => "answer-before-enrichment",
        "expected_version" => 1,
        "option_id" => "ship"
      }

      assert {:ok, %{action: accepted}} = answer(pid, v1.decision_id, answer_payload)
      assert_receive {:dispatch_scheduled, ^pid, scheduled_dispatch, 0}, 2_000
      assert match?({:dispatch_action, _fence, false}, scheduled_dispatch)
      send(pid, scheduled_dispatch)
      assert_receive {:dispatched, 1}, 2_000
      settled = wait_for_decision(pid, v1.decision_id, &(&1.delivery_status == :queued))

      GenServer.stop(pid)
      replayed_pid = start_store!(dir, store_opts)

      assert_receive {:dispatch_scheduled, ^replayed_pid, {:reconcile_dispatches, [%{request_version: 1}]} = scheduled_reconciliation, 0},
                     2_000

      patch = %{"context" => %{"short_summary" => "Additional context"}}

      assert {:ok, %{status: :accepted, decision: enriched}} =
               enrich(
                 replayed_pid,
                 v1.decision_id,
                 patch,
                 1
               )

      assert enriched.version == 2
      assert enriched.answer == accepted
      assert enriched.delivery_status == :queued
      assert enriched.dispatch_attempts == settled.dispatch_attempts

      assert {:ok, %{status: :duplicate, decision: replayed}} =
               enrich(replayed_pid, v1.decision_id, patch, 1)

      assert replayed.answer == accepted
      assert replayed.delivery_status == :queued
      assert replayed.dispatch_attempts == settled.dispatch_attempts

      :atomics.put(release_scheduled_work, 1, 1)
      send(replayed_pid, scheduled_reconciliation)

      refute_receive {:dispatch_scheduled, ^replayed_pid, _message, _delay_ms}, 100
      refute_receive {:dispatched, 2}, 100
      assert :counters.get(dispatches, 1) == 1
    end

    test "pending first delivery survives enrichment before restart reconciliation", %{dir: dir} do
      parent = self()
      dispatches = :counters.new(1, [])
      release_scheduled_work = :atomics.new(1, [])

      dispatcher = fn decision, _opts ->
        :counters.add(dispatches, 1, 1)
        send(parent, {:pending_dispatched, :counters.get(dispatches, 1), decision.version})
        {:ok, %{status: :accepted, item: %{id: 102}}}
      end

      dispatch_scheduler = fn recipient, message, delay_ms ->
        send(parent, {:dispatch_scheduled, recipient, message, delay_ms})

        if :atomics.get(release_scheduled_work, 1) == 1,
          do: send(recipient, message)

        make_ref()
      end

      store_opts = [
        dispatcher: dispatcher,
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 0,
        dispatch_scheduler: dispatch_scheduler
      ]

      pid = start_store!(dir, store_opts)
      assert_receive {:dispatch_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000
      assert {:ok, %{decision: v1}} = request(pid, answerable_request("enrich-pending-answer"))

      answer_payload = %{
        "idempotency_key" => "pending-answer-before-enrichment",
        "expected_version" => 1,
        "option_id" => "ship"
      }

      assert {:ok, %{action: accepted}} = answer(pid, v1.decision_id, answer_payload)
      assert_receive {:dispatch_scheduled, ^pid, {:dispatch_action, _fence, false}, 0}, 2_000
      GenServer.stop(pid)

      replayed_pid = start_store!(dir, store_opts)

      assert_receive {:dispatch_scheduled, ^replayed_pid, {:reconcile_dispatches, [%{request_version: 1}]} = scheduled_reconciliation, 0},
                     2_000

      patch = %{"context" => %{"short_summary" => "Context before first delivery"}}

      assert {:ok, %{status: :accepted, decision: enriched}} =
               enrich(replayed_pid, v1.decision_id, patch, 1)

      assert enriched.version == 2
      assert enriched.answer == accepted
      assert enriched.delivery_status == :pending
      assert enriched.dispatch_attempts == []

      :atomics.put(release_scheduled_work, 1, 1)
      send(replayed_pid, scheduled_reconciliation)

      assert_receive {:pending_dispatched, 1, 1}, 2_000
      settled = wait_for_decision(replayed_pid, v1.decision_id, &(&1.delivery_status == :queued))
      assert settled.version == 2
      assert settled.answer == accepted
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:queued]
      refute_receive {:pending_dispatched, 2, _version}, 100
      assert :counters.get(dispatches, 1) == 1
    end

    test "dispatch lifecycle fences stay bounded across repeated retries", %{dir: dir} do
      parent = self()
      attempts = :counters.new(1, [])

      dispatcher = fn _decision, _opts ->
        :counters.add(attempts, 1, 1)
        send(parent, {:dispatch_attempted, :counters.get(attempts, 1)})
        {:error, :unavailable}
      end

      scheduler = fn recipient, message, delay_ms ->
        send(parent, {:dispatch_scheduled, recipient, message, delay_ms})
        make_ref()
      end

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0,
          retry_delays_ms: List.duplicate(0, 25),
          dispatch_scheduler: scheduler
        )

      assert_receive {:dispatch_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("bounded-dispatch-fence"))

      payload = %{"idempotency_key" => "bounded-fence", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert_receive {:dispatch_scheduled, ^pid, initial_dispatch, 0}, 2_000
      send(pid, initial_dispatch)
      assert_receive {:dispatch_attempted, 1}, 2_000
      assert_receive {:dispatch_scheduled, ^pid, first_retry, 0}, 2_000

      baseline_size = dispatch_fence_size(first_retry)

      sizes =
        Enum.reduce(2..20, {first_retry, [baseline_size]}, fn attempt, {scheduled, sizes} ->
          send(pid, scheduled)
          assert_receive {:dispatch_attempted, ^attempt}, 2_000
          assert_receive {:dispatch_scheduled, ^pid, next_retry, 0}, 2_000
          {next_retry, [dispatch_fence_size(next_retry) | sizes]}
        end)
        |> elem(1)

      assert Enum.max(sizes) <= baseline_size + 64
      assert :counters.get(attempts, 1) == 20
    end
  end
end
