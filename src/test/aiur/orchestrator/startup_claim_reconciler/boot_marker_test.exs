defmodule Aiur.Orchestrator.StartupClaimReconciler.BootMarkerTest do
  use ExUnit.Case, async: false

  alias Aiur.Orchestrator.StartupClaimReconciler.BootMarker

  setup do
    on_exit(fn -> BootMarker.reset() end)
    BootMarker.reset()
    :ok
  end

  test "starts unclaimed" do
    assert BootMarker.claimed_boot_id() == nil
  end

  test "records and returns the claimed boot id" do
    :ok = BootMarker.claim("boot-123")
    assert BootMarker.claimed_boot_id() == "boot-123"
  end

  test "a claim survives a simulated Orchestrator restart (same VM) and reset clears it" do
    :ok = BootMarker.claim("boot-456")
    assert BootMarker.claimed_boot_id() == "boot-456"
    :ok = BootMarker.reset()
    assert BootMarker.claimed_boot_id() == nil
  end
end
