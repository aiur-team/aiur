defmodule Aiur.BuildOrder.BoundedTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.Bounded

  test "accepts only bounded secret-free opaque identifiers" do
    assert Bounded.opaque("run-1:attempt_2.3") == "run-1:attempt_2.3"
    assert Bounded.opaque("four", 4) == "four"

    assert Bounded.opaque("") == nil
    assert Bounded.opaque("fives", 4) == nil
    assert Bounded.opaque("contains spaces") == nil
    assert Bounded.opaque("ghp_" <> String.duplicate("a", 36)) == nil
    assert Bounded.opaque(42) == nil
  end
end
