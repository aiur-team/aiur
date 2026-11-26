defmodule Aiur.Stacking.MergeOrderTest do
  use ExUnit.Case, async: true
  alias Aiur.Stacking.MergeOrder

  defp merged(id, sha), do: %{id: id, pr: %{merged?: true, merge_commit_sha: sha}}
  defp always(answer), do: fn _sha -> answer end

  test "no blockers and contained merged blockers are fine" do
    assert MergeOrder.verdict([], always(:contained)) == :ok
    assert MergeOrder.verdict([merged("5", "abc")], always(:contained)) == :ok
  end

  test "an open or closed-unmerged blocker PR is a violation" do
    open = %{id: "5", pr: %{merged?: false, state: :open}}
    closed = %{id: "6", pr: %{merged?: false, state: :closed}}
    assert MergeOrder.verdict([open, closed], always(:contained)) == {:violation, ["5", "6"]}
  end

  test "a merged blocker outside the merged head is a violation" do
    assert MergeOrder.verdict([merged("5", "abc")], always(:not_contained)) == {:violation, ["5"]}
  end

  test "missing facts or unreadable containment are unverified, never ok" do
    assert MergeOrder.verdict([%{id: "5", pr: nil}], always(:contained)) == {:unverified, ["5"]}
    assert MergeOrder.verdict([merged("5", "abc")], always(:unknown)) == {:unverified, ["5"]}
    assert MergeOrder.verdict([merged("5", nil)], always(:contained)) == {:unverified, ["5"]}
  end

  test "a violation outranks an unverified blocker" do
    blockers = [%{id: "4", pr: nil}, %{id: "5", pr: %{merged?: false}}]
    assert MergeOrder.verdict(blockers, always(:contained)) == {:violation, ["5"]}
  end
end
