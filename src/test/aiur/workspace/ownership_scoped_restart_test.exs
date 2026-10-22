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
      assert is_pid(restart_store(prior, supervisor))
      assert Process.whereis(Aiur.Supervisor) == supervisor
    end)

    Aiur.TestScopeGuard.put_ticket_scope!("99")
    prior = Process.whereis(Ownership.Store)
    assert is_pid(prior)

    store = restart_store(prior, supervisor)
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

  defp restart_store(prior, supervisor) do
    monitor = Process.monitor(prior)
    Process.exit(prior, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^prior, _reason} -> :ok
    end

    # The supervisor handles this request after completing its rest_for_one
    # restart callback. An infinite call makes the synchronization depend on
    # the observed restart, not an arbitrary load-sensitive timeout.
    _children = GenServer.call(supervisor, :which_children, :infinity)
    Process.whereis(Ownership.Store)
  end
end
