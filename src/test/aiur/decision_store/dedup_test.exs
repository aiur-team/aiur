Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.DedupTest do
  use Aiur.DecisionStoreCase, async: false

  describe "supersede-and-clear on answer (#1844)" do
    test "answering a Command clears its open duplicates on the same ticket", %{dir: dir} do
      pid = start_store!(dir)
      question = "Should PR #1820 push its existing merge?"

      assert {:ok, %{decision: primary}} =
               request(pid, %{
                 "question" => question,
                 "blocking" => false,
                 "options" => [
                   %{"id" => "push_refresh", "label" => "Push the refresh"},
                   %{"id" => "keep_unpushed", "label" => "Keep it unpushed"}
                 ]
               })

      # The same question filed a second time as an option-less attention —
      # the exact #1844 shape. `source_id` differs, so nothing dedups it today;
      # it is filed by a *different* agent so creation-time dedup (#2099) does
      # not collapse it before the answer-time supersede can be exercised.
      assert {:ok, %{status: :accepted, decision: duplicate}} =
               project_attention(
                 pid,
                 %{
                   "question" => "  SHOULD PR #1820 push its existing `merge`.  ",
                   "blocking" => false,
                   "kind" => "legacy_attention",
                   "source_id" => "legacy_attention:push-question"
                 },
                 source: %{@source | agent_id: "agent-2"}
               )

      # A genuinely different question on the same ticket, and the same question
      # on a different ticket. Neither may be swept up.
      assert {:ok, %{decision: unrelated}} =
               request(pid, %{"question" => "Should we drop the index?", "blocking" => false})

      assert {:ok, %{decision: other_ticket}} =
               request(pid, %{"question" => question, "blocking" => false}, ticket: %{@ticket | identifier: "5150"})

      assert duplicate.decision_status == :open

      assert {:ok, %{status: :accepted}} =
               answer(pid, primary.decision_id, %{
                 "idempotency_key" => "answer-primary",
                 "expected_version" => primary.version,
                 "option_id" => "push_refresh"
               })

      assert {:ok, %Decision{decision_status: :dismissed} = cleared} =
               DecisionStore.get(duplicate.decision_id, pid)

      # The dismissal names the Command that answered it, so the audit trail
      # explains why a record the operator never touched closed itself.
      assert {:ok, audit} = DecisionStore.audit_history(cleared.decision_id, pid)

      assert Enum.any?(audit, fn record ->
               match?(%DecisionEvent{type: :decision_dismissed}, record) and
                 record.data.actor.id == "superseded-by:#{primary.decision_id}"
             end)

      assert {:ok, %Decision{decision_status: :open}} = DecisionStore.get(unrelated.decision_id, pid)
      assert {:ok, %Decision{decision_status: :open}} = DecisionStore.get(other_ticket.decision_id, pid)
    end

    test "an agent-filed blocking duplicate is never silently cleared", %{dir: dir} do
      pid = start_store!(dir)
      question = "Which owner should take this?"

      assert {:ok, %{decision: primary}} =
               request(pid, %{"question" => question, "blocking" => false})

      # Blocking, agent-filed, no legacy attention: `unresolvable_block?/1`
      # refuses dismissal because it would release nothing to the waiting agent.
      # Superseding must respect that rather than route around it.
      assert {:ok, %{decision: blocking_twin}} =
               request(pid, %{"question" => question, "blocking" => true})

      assert {:ok, %{status: :accepted}} =
               answer(pid, primary.decision_id, %{
                 "idempotency_key" => "answer-owner",
                 "expected_version" => primary.version,
                 "custom_response" => "Platform owns it"
               })

      assert {:ok, %Decision{decision_status: :open}} =
               DecisionStore.get(blocking_twin.decision_id, pid)

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert MapSet.member?(ids, "979")
    end
  end

  describe "creation-time dedup (#2099)" do
    test "an exact-identical re-file from the same agent stays a distinct Command", %{dir: dir} do
      pid = start_store!(dir)
      question = "Should PR #1820 push its existing merge?"

      # An identical re-file is the agent deliberately asking the same question
      # again (e.g. a distinct tool call), not an accidental duplicate: the
      # tool-call/retry contract depends on this, so it stays its own row.
      assert {:ok, %{status: :accepted, decision: first}} =
               request(pid, %{"question" => question, "blocking" => false, "source_id" => "ask-1"})

      assert {:ok, %{status: :accepted, decision: second}} =
               request(pid, %{"question" => question, "blocking" => false, "source_id" => "ask-2"})

      refute second.decision_id == first.decision_id

      assert decisions = DecisionStore.list(pid)
      assert length(decisions) == 2
    end

    test "paraphrases of one question from the same agent collapse within the window", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: first}} =
               request(pid, %{
                 "question" => "Should ticket #2071 be reclassified for fresh implementation, or should the missing prior PR/ref and review feedback be restored first?",
                 "blocking" => false,
                 "source_id" => "q1"
               })

      assert {:ok, %{status: :duplicate, decision: second}} =
               request(pid, %{
                 "question" => "Ticket #2071 has no prior PR/ref or review feedback; choose fresh implementation or artifact restoration",
                 "blocking" => false,
                 "source_id" => "q2"
               })

      assert {:ok, %{status: :duplicate, decision: third}} =
               request(pid, %{
                 "question" => "Reclassify #2071 for fresh implementation, or restore the missing prior PR/ref and review feedback?",
                 "blocking" => false,
                 "source_id" => "q3"
               })

      # All three collapse to the first Command.
      assert second.decision_id == first.decision_id
      assert third.decision_id == first.decision_id

      assert decisions = DecisionStore.list(pid)
      assert length(decisions) == 1
    end

    test "a different agent or ticket does not collapse", %{dir: dir} do
      pid = start_store!(dir)
      question = "Should we drop the index?"

      assert {:ok, %{decision: agent_a}} = request(pid, %{"question" => question, "blocking" => false})

      assert {:ok, %{decision: agent_b}} =
               request(pid, %{"question" => question, "blocking" => false}, source: %{@source | agent_id: "agent-2"})

      assert {:ok, %{decision: other_ticket}} =
               request(pid, %{"question" => question, "blocking" => false}, ticket: %{@ticket | identifier: "5150"})

      refute agent_b.decision_id == agent_a.decision_id
      refute other_ticket.decision_id == agent_a.decision_id

      assert decisions = DecisionStore.list(pid)
      assert length(decisions) == 3
    end

    test "an answered Command is not a dedup candidate for a new similar one", %{dir: dir} do
      pid = start_store!(dir)
      question = "Which owner should take this?"

      assert {:ok, %{decision: first}} =
               request(pid, %{"question" => question, "blocking" => false, "source_id" => "first"})

      assert {:ok, %{status: :accepted, decision: decided}} =
               answer(pid, first.decision_id, %{
                 "idempotency_key" => "answer",
                 "expected_version" => 1,
                 "custom_response" => "Platform"
               })

      assert decided.decision_status == :decided

      # A decided Command no longer represents an open question, so a fresh
      # similar Command from the same agent creates its own row.
      assert {:ok, %{status: :accepted, decision: fresh}} =
               request(pid, %{
                 "question" => question,
                 "blocking" => false,
                 "source_id" => "fresh",
                 now: DateTime.add(DateTime.utc_now(), 5, :second)
               })

      refute fresh.decision_id == first.decision_id
      assert fresh.decision_status == :open
    end

    test "attention projections dedup against a recent same-agent Command", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: first}} =
               request(pid, %{
                 "question" => "Should ticket #2071 be reclassified for fresh implementation?",
                 "blocking" => false,
                 "source_id" => "agent-request"
               })

      assert {:ok, %{status: :duplicate, decision: duplicate}} =
               project_attention(pid, %{
                 "question" => "Reclassify ticket #2071 for fresh implementation?",
                 "blocking" => false,
                 "kind" => "legacy_attention",
                 "source_id" => "legacy_attention:2071-reclassify"
               })

      assert duplicate.decision_id == first.decision_id

      assert decisions = DecisionStore.list(pid)
      assert length(decisions) == 1
    end
  end
end
