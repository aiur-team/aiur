defmodule Aiur.Opencode.ActiveTurnsTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.ActiveTurns

  setup do
    # Application starts the GenServer; ensure a fresh-looking table by
    # using unique identifiers per test rather than truncating shared state.
    :ok
  end

  describe "lookup/2" do
    test "returns :not_found for unregistered ids" do
      assert ActiveTurns.lookup("test-#{System.unique_integer()}", "tDEAD") == :not_found
    end

    test "returns :active after put/2" do
      id = "test-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"
      :ok = ActiveTurns.put(id, turn)

      assert ActiveTurns.lookup(id, turn) == :active
    end

    test "returns {:closed, reason} after mark_closed/3" do
      id = "test-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"
      :ok = ActiveTurns.put(id, turn)
      :ok = ActiveTurns.mark_closed(id, turn, :done)

      assert ActiveTurns.lookup(id, turn) == {:closed, :done}
    end

    test "mark_closed/3 preserves the reason verbatim" do
      id = "test-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"
      :ok = ActiveTurns.put(id, turn)
      :ok = ActiveTurns.mark_closed(id, turn, {:failed, :timeout})

      assert ActiveTurns.lookup(id, turn) == {:closed, {:failed, :timeout}}
    end

    test "entries for distinct (identifier, turn) pairs are independent" do
      id_a = "a-#{System.unique_integer()}"
      id_b = "b-#{System.unique_integer()}"
      turn = "t-shared"

      :ok = ActiveTurns.put(id_a, turn)
      assert ActiveTurns.lookup(id_a, turn) == :active
      assert ActiveTurns.lookup(id_b, turn) == :not_found
    end
  end
end
