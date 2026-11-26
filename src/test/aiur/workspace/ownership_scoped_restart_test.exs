defmodule Aiur.Workspace.OwnershipScopedRestartTest do
  use Aiur.TestSupport

  alias Aiur.Workspace.Ownership

  # #4736: under a partial ticket scope the Store's restart cannot resolve its
  # decision-state path, the supervisor gives up, and later tests see
  # `unknown registry: Aiur.Workspace.Ownership.Registry`.
  test "a child crash under the test ticket scope restarts the ownership registry" do
    supervisor = Process.whereis(Aiur.Supervisor)
    assert is_pid(supervisor)

    # Registered first so it runs after the scope env is restored but before
    # TestSupport removes workflow_root, moving the Store off the scoped path.
    on_exit(fn ->
      prior = Process.whereis(Ownership.Store)
      assert is_pid(prior)
      Process.exit(prior, :kill)
      assert {:ok, store} = Aiur.TestSupport.await_supervised_restart_unbounded(Ownership.Store, prior)
      assert is_pid(store)
      assert Process.whereis(Aiur.Supervisor) == supervisor
    end)

    Aiur.TestScopeGuard.put_ticket_scope!("99")
    prior = Process.whereis(Ownership.Store)
    assert is_pid(prior)

    Process.exit(prior, :kill)

    assert {:ok, store} = Aiur.TestSupport.await_supervised_restart_unbounded(Ownership.Store, prior)
    assert is_pid(store)
    assert store != prior
    assert Process.whereis(Aiur.Supervisor) == supervisor
    assert Registry.lookup(Ownership.Registry, "99") == []
  end

  # Fails with `{:persist_failed, :enoent}` when the test above leaves the
  # Store on its deleted scoped path; the seed decides which runs first.
  test "claims persist after the scoped restart test" do
    assert {:ok, lease} = Ownership.claim("4736-after-scoped-restart")
    assert :ok = Ownership.release(lease)
  end
end
