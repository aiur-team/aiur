defmodule Aiur.BuildQueue.DispatchTriggerHintsTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.{Hints, Reconcile}

  test "effective queue trigger reaches dispatch and retains rank and hold" do
    :ets.new(Hints.table_name(), [:named_table, :set])
    document = %{queues: [%{id: "q", held: false, start_trigger: :pr_opened}], items: [%{issue_id: "12", queue_id: "q", hold: nil}]}
    projections = [%{issue_id: "12", state: :waiting, rank: {-2, 0, 3, 0, "12"}}]

    Reconcile.write_hints(projections, MapSet.new(["12"]), document)

    assert Hints.trigger_for("12") == :pr_opened
    assert Hints.sort_key("12") == {-2, 3}
    assert Hints.held?("12")
  end

  test "missing table, missing row and legacy row use the configured default" do
    assert Hints.trigger_for("12") == :pr_merged
    :ets.new(Hints.table_name(), [:named_table, :set])
    assert Hints.trigger_for("12") == :pr_merged
    :ets.insert(Hints.table_name(), {"12", {-3, 2}, true})
    assert Hints.trigger_for("12") == :pr_merged
    assert Hints.sort_key("12") == {-3, 2}
    assert Hints.held?("12")
  end
end
