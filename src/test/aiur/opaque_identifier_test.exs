defmodule Aiur.OpaqueIdentifierTest do
  use Aiur.TestSupport

  alias Aiur.OpaqueIdentifier

  test "accepts only bounded secret-free opaque identifiers" do
    assert OpaqueIdentifier.normalize("run-1:attempt_2.3") == "run-1:attempt_2.3"
    assert OpaqueIdentifier.normalize("four", 4) == "four"

    assert OpaqueIdentifier.normalize("") == nil
    assert OpaqueIdentifier.normalize("fives", 4) == nil
    assert OpaqueIdentifier.normalize("contains spaces") == nil
    assert OpaqueIdentifier.normalize("ghp_" <> String.duplicate("a", 36)) == nil
    assert OpaqueIdentifier.normalize(<<255>>) == nil
    assert OpaqueIdentifier.normalize(42) == nil
  end
end
