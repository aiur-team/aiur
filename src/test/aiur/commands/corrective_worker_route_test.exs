defmodule Aiur.Commands.CorrectiveWorkerRouteTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.{CorrectiveFacts, CorrectiveFailures, Overrides}
  alias Aiur.Decision
  alias Aiur.DecisionStore.Overrides, as: StoreOverrides

  test "later corrective overrides retain the observed active, resumable and capacity-limited worker routes" do
    now = DateTime.utc_now()
    original = %{identifier: "42"}
    corrective = %{identifier: "43", title: "Correction", url: "https://example.test/issues/43"}
    decision = struct(Decision, decision_id: "command", ticket: original, active_action_id: "first")
    metadata = StoreOverrides.metadata(override_context: %{pr: %{merged?: true}, worker: :active, capacity: :available})
    first = Overrides.observe(decision, revision("first", metadata, now))
    link = %{type: :override_corrective_ticket, data: %{action_id: "first", ticket: corrective, pr_number: 77, merge_commit_sha: "merge"}, occurred_at: now}
    assert {:ok, linked} = CorrectiveFacts.apply(first, link)

    for {worker, capacity, expected} <- [{:active, :available, :active_worker}, {:parked, :available, :resume_pending}, {:parked, :full, :capacity_wait}] do
      context = %{pr: %{merged?: false}, worker: worker, capacity: capacity}
      metadata = StoreOverrides.metadata(override_context: context)
      latest = Overrides.observe(%{linked | active_action_id: "second"}, revision("second", metadata, now))
      assert %{route: ^expected, corrective_ticket: ^corrective, ticket: ^corrective} = List.last(latest.overrides)
      assert Overrides.target_ticket(latest) == corrective
      assert latest.ticket == original
    end
  end

  test "delivery remains visible when corrective observation fails before or after transport" do
    now = DateTime.utc_now()
    metadata = StoreOverrides.metadata(override_context: %{pr: :unknown, worker: :active, capacity: :available})
    decision = struct(Decision, decision_id: "command", ticket: %{identifier: "42"}, active_action_id: "first")
    queued = Overrides.observe(decision, revision("first", metadata, now))
    failure = CorrectiveFailures.build(List.last(queued.overrides), :outcome_unknown, now)
    assert {:ok, failed} = CorrectiveFacts.apply(queued, %{type: :override_corrective_failed, data: failure, occurred_at: now})
    assert [%{state: :failed}] = failed.overrides

    delivered = Overrides.observe(failed, %{type: :delivered, data: %{action_id: "first"}, occurred_at: now})
    assert [%{state: :delivered, delivered_at: ^now, failure: %{attempts: 1}}] = delivered.overrides
    assert {:ok, observed} = CorrectiveFacts.apply(delivered, %{type: :override_corrective_failed, data: failure, occurred_at: now})
    assert [%{state: :delivered, delivered_at: ^now, failure: %{attempts: 1}}] = observed.overrides
  end

  defp revision(action, metadata, now) do
    %{type: :revision_recorded, data: %{action_id: action, prior_action_id: "original", override: metadata}, occurred_at: now}
  end
end
