defmodule Aiur.Commands.OverridesTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.Overrides
  alias Aiur.Decision

  @at ~U[2026-10-27 12:00:00Z]
  @metadata %{pr_number: 77, pr_merged: false, pr_head_sha: "before", pr_head_ref: "work", route: :active_worker}

  test "metadata round trips JSON without creating arbitrary atoms" do
    assert {:ok, @metadata} = @metadata |> Aiur.JSONSafe.normalize() |> Overrides.normalize_metadata()
    assert {:ok, nil} = Overrides.normalize_metadata(nil)

    for invalid <- [%{@metadata | route: "new_route"}, %{@metadata | pr_number: -1}, %{@metadata | pr_head_ref: String.duplicate("x", 257)}, %{@metadata | pr_merged: nil}] do
      assert {:error, :invalid_override_metadata} = Overrides.normalize_metadata(invalid)
    end
  end

  test "override record preserves provenance and delivery is distinct from implementation" do
    decision = record("action-1")
    assert [override] = decision.overrides
    assert override.decision_id == "command"
    assert override.prior_action_id == "original"
    assert override.ticket == %{identifier: "6908"}
    assert override.pr_number == 77
    assert override.state == :queued
    assert override.queued_at == @at

    delivered = Overrides.observe(decision, %{type: :delivered, data: %{action_id: "action-1"}, occurred_at: DateTime.add(@at, 1)})
    assert [override] = delivered.overrides
    assert override.state == :delivered
    assert override.delivered_at == DateTime.add(@at, 1)
    assert Overrides.observe(delivered, %{type: :consumed}) == delivered

    acknowledged = Overrides.observe(delivered, %{type: :acknowledged, data: %{action_id: "action-1"}, occurred_at: DateTime.add(@at, 2)})
    assert [%{state: :implemented, evidence: :acknowledged, implemented_at: implemented_at}] = acknowledged.overrides
    assert implemented_at == DateTime.add(@at, 2)
  end

  test "a subsequent override supersedes prior implemented work in journal order" do
    first = record("action-1") |> Overrides.observe(%{type: :acknowledged, data: %{action_id: "action-1"}, occurred_at: @at})
    second = record("action-2", first)
    assert [%{state: :superseded}, %{state: :queued, action_id: "action-2"}] = second.overrides
    late = Overrides.observe(second, %{type: :delivered, data: %{action_id: "action-1"}, occurred_at: @at})
    assert late == second
  end

  test "third override preserves the first supersession time and parked routes stay queued" do
    second = record("action-2", record("action-1"))

    third =
      Overrides.observe(second, %{
        type: :revision_recorded,
        occurred_at: DateTime.add(@at, 20),
        data: %{override: %{@metadata | route: :resume_pending}, action_id: "action-3", prior_action_id: "action-2"}
      })

    assert [first, middle, newest] = third.overrides
    assert first.superseded_at == @at
    assert middle.superseded_at == DateTime.add(@at, 20)
    assert newest.state == :queued
    assert Overrides.observe(third, %{type: :acknowledged, data: %{action_id: "action-3"}, occurred_at: DateTime.add(@at, 21)}) == third
  end

  test "only a changed head on the same PR after delivery proves implementation" do
    decision = record("action-1") |> Overrides.observe(%{type: :delivered, data: %{action_id: "action-1"}, occurred_at: @at})
    data = %{action_id: "action-1", at: DateTime.add(@at, 1), head_sha: "after", pr_number: 77}
    assert {:ok, updated} = Overrides.implemented(decision, %{data: data})
    assert [%{state: :implemented, evidence: %{kind: :push, head_sha: "after", pr_number: 77}}] = updated.overrides

    for invalid <- [%{data | head_sha: "before"}, %{data | pr_number: 78}, %{data | at: @at}, %{data | action_id: "other"}] do
      assert {:error, :override_push_mismatch} = Overrides.implemented(decision, %{data: invalid})
    end
  end

  defp record(action_id, decision \\ struct(Decision, decision_id: "command", ticket: %{identifier: "6908"})) do
    decision = %{decision | active_action_id: action_id}
    Overrides.observe(decision, %{type: :revision_recorded, occurred_at: @at, data: %{override: @metadata, action_id: action_id, prior_action_id: "original"}})
  end
end
