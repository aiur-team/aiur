defmodule Aiur.Stacking.StackBaseTest do
  use ExUnit.Case, async: true
  alias Aiur.Stacking.StackBase

  test "only an open unmerged direct blocker's branch is accepted" do
    open = %{state: :open, merged?: false, head_ref: "blocker"}
    assert StackBase.decide("blocker", "main", [%{id: "42", pr: open}]) == {:ok, {:stacked, "42"}}

    for facts <- [%{open | merged?: true}, %{open | state: :closed, merged?: true}, %{open | state: :closed}, nil, Map.delete(open, :merged?), %{open | head_ref: nil}] do
      assert StackBase.decide("blocker", "main", [%{id: "42", pr: facts}]) == {:repair, "main"}
    end

    assert StackBase.decide("unrelated", "main", [%{id: "42", pr: open}]) == {:repair, "main"}
    assert StackBase.decide("blocker", "main", []) == {:repair, "main"}
    assert StackBase.decide("main", "main", []) == {:ok, :integration}
    assert StackBase.decide(nil, "main", [%{id: "42", pr: open}]) == {:repair, "main"}
  end
end
