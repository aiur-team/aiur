defmodule Aiur.PrMerge.ApprovalGateTest do
  use ExUnit.Case, async: true
  alias Aiur.PrMerge.Gate
  @head String.duplicate("a", 40)
  @policy %{ci: "wait", attribution_scan: false}
  @opts %{reviewed_sha: @head, approve_body: nil, inherited: []}
  @pr %{head: @head, state: "OPEN", draft: false, conflict: false, approved: true, changes_requested: false, bypass: false, failed: [], required: [], passed: []}

  test "neither bypass identity nor a proposed review replaces current-head approval" do
    assert Gate.refusals(%{@pr | approved: false, bypass: true}, @policy, @opts) == ["approval at current head required"]
    pr = Map.merge(@pr, %{approved: false, author_id: 10, operator_id: 20})
    assert Gate.refusals(pr, @policy, %{@opts | approve_body: "Reviewed"}) == ["approval at current head required"]
  end

  test "requested changes refuse even with another current-head approval and bypass" do
    assert Gate.refusals(%{@pr | changes_requested: true, bypass: true}, @policy, @opts) == ["changes requested by reviewer"]
  end

  test "requested approval refuses self-review and missing author identity" do
    for attrs <- [%{author_id: 10, operator_id: 10}, %{author_id: nil, operator_id: 20}, %{author_id: 10, operator_id: nil}] do
      assert Gate.refusals(Map.merge(@pr, attrs), @policy, %{@opts | approve_body: "Reviewed"}) == ["approval requires a known PR author distinct from operator"]
    end

    assert Gate.refusals(Map.merge(@pr, %{author_id: 10, operator_id: 20}), @policy, %{@opts | approve_body: "Reviewed"}) == []
  end
end
