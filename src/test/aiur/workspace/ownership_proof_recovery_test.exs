defmodule Aiur.Workspace.OwnershipProofRecoveryTest do
  use ExUnit.Case, async: false

  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.{Guardian, Store}

  @registry __MODULE__.Registry
  @store __MODULE__.Store

  setup do
    root = Path.join(System.tmp_dir!(), "ownership-proof-#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!({Store, name: @store, state_dir: root, sync_fun: fn -> :ok end})
    on_exit(fn -> File.rm_rf!(root) end)
    :ok
  end

  test "durable no-spawn confirmation completes a restored generation's pending release" do
    ticket = "533"
    receipt = %{ticket: ticket, generation: 9012, owner_id: "workspace:9012", phase: :reaping, provider_expected?: true, provider: nil, provider_cleanup: :unresolved}
    assert :ok = Store.put(ticket, receipt, @store)
    assert {:ok, lease} = Guardian.restore(receipt, @registry, store: @store)
    monitor = Process.monitor(lease.guardian)
    on_exit(fn -> if Process.alive?(lease.guardian), do: Process.exit(lease.guardian, :kill) end)

    assert {:waiting, guardian, generation} = Ownership.wait_for_release(ticket, self(), @registry)
    assert guardian == lease.guardian
    assert generation == 9012
    refute_receive {:workspace_ownership_available, _, _, _}, 30
    assert {:error, :workspace_ownership_lost} = Ownership.cancel_provider_expectation(%{lease | generation: 9013})
    assert {:ok, %{provider_expected?: true}} = Store.get(ticket, @store)

    # This existing API is reserved for startup paths that prove no process
    # was spawned. An elapsed timeout or absent PID must never call it.
    assert :ok = Ownership.cancel_provider_expectation(lease)
    assert_receive {:workspace_ownership_available, ^ticket, ^guardian, ^generation}, 500
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 500
    assert {:ok, nil} = Store.get(ticket, @store)
    assert :none = Ownership.current(ticket, @registry)
  end

  test "late no-spawn confirmation wakes an already pending release_and_wait" do
    ticket = "pending"
    assert {:ok, lease} = Ownership.claim(ticket, @registry, store: @store)
    on_exit(fn -> if Process.alive?(lease.guardian), do: Process.exit(lease.guardian, :kill) end)
    assert :ok = Ownership.expect_provider(lease)
    ref = make_ref()
    send(lease.guardian, {:workspace_guardian_call, self(), ref, {:release_and_wait, lease.generation}})
    # The following synchronous call is ordered behind the release request.
    assert :ok = Ownership.cancel_provider_expectation(lease)
    assert_receive {:workspace_guardian_reply, ^ref, {:ok, %{phase: :released}}}, 500
    assert {:ok, nil} = Store.get(ticket, @store)
    assert :none = Ownership.current(ticket, @registry)
  end
end
