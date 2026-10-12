defmodule Aiur.BuildQueue.HintsTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildQueue.Hints

  test "absent table defaults to ordinary rank and no hold" do
    assert :ets.whereis(Hints.table_name()) == :undefined
    assert Hints.sort_key("7") == {0, 0}
    refute Hints.held?("7")
  end

  test "reads queue rows and defaults missing rows" do
    :ets.new(Hints.table_name(), [:named_table, :set])
    :ets.insert(Hints.table_name(), [{"7", {-3, 2}, true}, {"8", {-1, 4}, false}])

    assert Hints.sort_key("7") == {-3, 2}
    assert Hints.held?("7")
    assert Hints.sort_key("8") == {-1, 4}
    refute Hints.held?("8")
    assert Hints.sort_key("missing") == {0, 0}
    refute Hints.held?("missing")
  end
end
