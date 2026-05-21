defmodule Aiur.Opencode.TokenRegistryTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Opencode.TokenRegistry

  test "validates tokens by presence alone" do
    refute TokenRegistry.valid?("token-a")

    assert :ok = TokenRegistry.put("token-a", 1, 1)
    assert TokenRegistry.valid?("token-a")
    refute TokenRegistry.valid?("token-b")

    assert :ok = TokenRegistry.delete("token-a")
    refute TokenRegistry.valid?("token-a")
  end

  test "delete_stale removes only entries with older generation for the given slot" do
    # slot 1 gens 1 + 2; slot 2 gen 1
    TokenRegistry.put("slot1-old", 1, 1)
    TokenRegistry.put("slot1-new", 1, 2)
    TokenRegistry.put("slot2-only", 2, 1)

    # Sweep slot 1 anything older than gen 2 — only slot1-old should go.
    assert :ok = TokenRegistry.delete_stale(1, 2)

    refute TokenRegistry.valid?("slot1-old")
    assert TokenRegistry.valid?("slot1-new")
    assert TokenRegistry.valid?("slot2-only")

    # Cleanup
    TokenRegistry.delete("slot1-new")
    TokenRegistry.delete("slot2-only")
  end

  test "overlap window: both old and new tokens validate until delete_stale runs" do
    # Simulates the strict overlap order during a slot serve restart.
    TokenRegistry.put("old-token", 1, 1)
    # ... slot bumps generation, registers new before tearing down old ...
    TokenRegistry.put("new-token", 1, 2)

    assert TokenRegistry.valid?("old-token")
    assert TokenRegistry.valid?("new-token")

    # ... new attach reports ready; slot sweeps stale ...
    TokenRegistry.delete_stale(1, 2)

    refute TokenRegistry.valid?("old-token")
    assert TokenRegistry.valid?("new-token")

    TokenRegistry.delete("new-token")
  end

  test "rapid put/delete/put on the same token (restart simulation) ends valid" do
    TokenRegistry.put("recycled", 1, 1)
    TokenRegistry.delete("recycled")
    refute TokenRegistry.valid?("recycled")

    TokenRegistry.put("recycled", 1, 2)
    assert TokenRegistry.valid?("recycled")

    TokenRegistry.delete("recycled")
  end
end
