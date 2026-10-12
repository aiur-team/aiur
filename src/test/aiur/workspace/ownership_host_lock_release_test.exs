defmodule Aiur.Workspace.OwnershipHostLockReleaseTest do
  use Aiur.TestSupport

  alias Aiur.Workspace.{HostLock, Ownership}

  test "release notification follows host lock removal" do
    ticket = "ownership-release-#{System.unique_integer([:positive])}"
    root = Aiur.TestSupport.tmp_root!("ownership-release")
    workspace = Path.join(root, ticket)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    assert {:ok, lease} = Ownership.claim(ticket)
    assert {:ok, lock} = HostLock.acquire(workspace, ticket)
    assert :ok = HostLock.handoff_to_ownership(lock, lease)
    assert {:waiting, guardian, generation} = Ownership.wait_for_release(ticket, self())

    assert {:ok, %{phase: :released}} = Ownership.release_and_wait(lease)
    receive_barrier({:workspace_ownership_available, ^ticket, ^guardian, ^generation})
    assert :none = HostLock.holder(workspace)
    assert :none = Ownership.current(ticket)
  end
end
