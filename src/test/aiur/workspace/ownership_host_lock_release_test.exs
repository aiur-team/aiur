defmodule Aiur.Workspace.OwnershipHostLockReleaseTest do
  use Aiur.TestSupport

  alias Aiur.Workspace.{HostLock, Ownership}

  test "release notification observes host lock removal before notifying waiters" do
    ticket = "ownership-release-#{System.unique_integer([:positive])}"
    root = Aiur.TestSupport.tmp_root!("ownership-release")
    workspace = Path.join(root, ticket)
    parent = self()
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               before_notify_fun: fn _waiter ->
                 send(parent, {:host_lock_at_notification, HostLock.holder(workspace)})
               end
             )

    assert {:ok, lock} = HostLock.acquire(workspace, ticket)
    assert :ok = HostLock.handoff_to_ownership(lock, lease)
    assert {:waiting, guardian, generation} = Ownership.wait_for_release(ticket, self())

    assert {:ok, %{phase: :released}} = Ownership.release_and_wait(lease)
    assert_receive {:host_lock_at_notification, :none}, 1_000
    receive_barrier({:workspace_ownership_available, ^ticket, ^guardian, ^generation})
    assert :none = HostLock.holder(workspace)
    assert :none = Ownership.current(ticket)
  end
end
