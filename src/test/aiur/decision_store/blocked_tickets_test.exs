Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.BlockedTicketsTest do
  use Aiur.DecisionStoreCase, async: false

  describe "blocked_ticket_ids/1 (#1965)" do
    test "returns ticket identifiers with open blocking Commands only", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: blocking}} =
               request(
                 pid,
                 %{"question" => "Open a blocker?", "blocking" => true},
                 ticket: %{@ticket | identifier: "11"}
               )

      assert {:ok, %{decision: non_blocking}} =
               request(
                 pid,
                 %{"question" => "Notice only?", "blocking" => false},
                 ticket: %{@ticket | identifier: "22"}
               )

      non_blocking_id = non_blocking.decision_id

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert ids == MapSet.new(["11"])

      # Answering the blocker releases the ticket on the next read.
      assert {:ok, %{status: :accepted}} =
               answer(pid, blocking.decision_id, %{
                 "idempotency_key" => "answer-blocker",
                 "expected_version" => blocking.version,
                 "custom_response" => "Proceed"
               })

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert ids == MapSet.new()

      # The non-blocking Command is untouched (it was never in the set).
      assert {:ok, %Decision{decision_id: ^non_blocking_id}} =
               DecisionStore.get(non_blocking_id, pid)
    end

    test "open_blocking_decision_ids/2 names the Commands that hold a ticket (#2699)", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: blocking}} =
               request(pid, %{"question" => "Hold ticket 52?", "blocking" => true}, ticket: %{@ticket | identifier: "52"})

      assert {:ok, %{decision: _notice}} =
               request(pid, %{"question" => "Notice on 52?", "blocking" => false}, ticket: %{@ticket | identifier: "52"})

      assert {:ok, %{decision: _other}} =
               request(pid, %{"question" => "Hold ticket 53?", "blocking" => true}, ticket: %{@ticket | identifier: "53"})

      assert DecisionStore.open_blocking_decision_ids(["52"], pid) == {:ok, [blocking.decision_id]}
      assert DecisionStore.open_blocking_decision_ids(["unknown"], pid) == {:ok, []}

      assert {:ok, %{status: :accepted}} =
               answer(pid, blocking.decision_id, %{
                 "idempotency_key" => "answer-52",
                 "expected_version" => blocking.version,
                 "custom_response" => "Proceed"
               })

      assert DecisionStore.open_blocking_decision_ids(["52"], pid) == {:ok, []}
    end

    test "open_blocking_decision_ids/2 reports an unreachable store" do
      assert DecisionStore.open_blocking_decision_ids(["52"], :no_such_decision_store) == {:error, :store_unavailable}
    end

    test "a deferred blocking Command still gates dispatch until answered", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: decision}} =
               request(
                 pid,
                 %{"question" => "Defer this blocker?", "blocking" => true},
                 ticket: %{@ticket | identifier: "33"}
               )

      assert {:ok, %{decision: deferred}} =
               DecisionStore.defer(decision.decision_id, [actor: %{kind: :operator, id: "dashboard"}], pid)

      assert deferred.decision_status == :deferred
      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert MapSet.member?(ids, "33")

      assert {:ok, %{decision: answered}} =
               answer(pid, decision.decision_id, %{
                 "idempotency_key" => "answer-deferred-blocker",
                 "expected_version" => 1,
                 "custom_response" => "Proceed"
               })

      assert answered.decision_status == :decided
      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      refute MapSet.member?(ids, "33")
    end

    test "an expired blocker stays answerable but does not strand a later dispatch", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: decision}} =
               request(pid, %{"question" => "Can the next worker retry?", "blocking" => true})

      assert {:ok, %{status: :accepted, decision: %{decision_status: :expired}}} =
               DecisionStore.expire(
                 decision.decision_id,
                 "agent_not_running",
                 [now: DateTime.add(decision.created_at, 600, :second)],
                 pid
               )

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      refute MapSet.member?(ids, "979")

      assert {:ok, %{decisions: [retained]}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: :open, search: nil, ticket: nil},
                 pid
               )

      assert retained.decision_id == decision.decision_id
      assert retained.decision_status == :expired
    end

    test "option-less legacy attentions never gate dispatch, but real blockers do", %{dir: dir} do
      pid = start_store!(dir)
      slug = "decision-delivery-act-1"

      assert {:ok, %{status: :accepted, decision: delivery_alert}} =
               DecisionStore.project_attention(
                 %{
                   "question" => "Decision action remains actionable after turn_failed.",
                   "blocking" => true,
                   "kind" => "legacy_attention",
                   "source_id" => "legacy_attention:#{slug}"
                 },
                 [
                   ticket: @ticket,
                   source: @source,
                   legacy_attention: %{slug: slug, topic: "ticket.979.agent.attention.#{slug}"}
                 ],
                 pid
               )

      assert delivery_alert.blocking

      # #1844: an option-less legacy attention does not gate dispatch either,
      # even when the persisted record still says `blocking: true` — records
      # written before attentions were filed unblocking are still in the store,
      # and each one would otherwise hold the whole ticket's dispatch.
      assert {:ok, %{status: :accepted, decision: attention}} =
               project_attention(pid, minimal_attention("Which owner should take this?"))

      assert attention.blocking
      assert attention.options == []

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert ids == MapSet.new()

      # A real agent-filed blocking Command on the same ticket still gates it,
      # so the exclusion is scoped to attentions rather than disarming the gate.
      assert {:ok, %{decision: _blocker}} =
               request(pid, %{"question" => "Drop the index?", "blocking" => true})

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert MapSet.member?(ids, "979")
    end

    test "fails closed when the store cannot be read", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: _decision}} = request(pid, %{"question" => "Block?", "blocking" => true})

      :sys.replace_state(pid, &%{&1 | writable?: false, health: {:unavailable, :test}})
      assert {:error, :store_unavailable} = DecisionStore.blocked_ticket_ids(pid)

      GenServer.stop(pid)
      assert {:error, :store_unavailable} = DecisionStore.blocked_ticket_ids(pid)
    end
  end
end
