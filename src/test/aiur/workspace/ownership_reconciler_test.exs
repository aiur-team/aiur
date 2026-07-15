defmodule Aiur.Workspace.OwnershipReconcilerTest do
  use ExUnit.Case, async: false

  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.{Reconciler, Store}

  test "a persisted unresolved group is reaped before a replacement lease after restart" do
    root = Path.join(System.tmp_dir!(), "ownership-restart-#{System.unique_integer([:positive])}")
    ticket = "ownership-restart-ticket-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    parent = self()
    store_name = Module.concat(__MODULE__, :FirstStore)
    registry_name = Module.concat(__MODULE__, :FirstRegistry)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, first_store} = start_supervised({Store, name: store_name, state_dir: root, sync_fun: fn -> :ok end})
    {:ok, _first_registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    assert {:ok, lease} =
             Ownership.claim(ticket, registry_name,
               store: first_store,
               process_identity_fun: fn ^process_group_id -> {:ok, :original} end
             )

    assert :ok = Ownership.expect_provider(lease)
    assert :ok = Ownership.track_process_group(lease, process_group_id)
    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket, registry_name) == :none end)

    stop_supervised(registry_name)
    stop_supervised(Store)

    second_store_name = Module.concat(__MODULE__, :SecondStore)
    second_registry_name = Module.concat(__MODULE__, :SecondRegistry)
    reconciler_name = Module.concat(__MODULE__, :Reconciler)
    {:ok, alive} = Agent.start_link(fn -> true end)

    on_exit(fn -> if Process.alive?(alive), do: Agent.stop(alive) end)

    {:ok, second_store} =
      start_supervised({Store, name: second_store_name, state_dir: root, sync_fun: fn -> :ok end})

    {:ok, _second_registry} = start_supervised({Registry, keys: :unique, name: second_registry_name})

    assert {:ok, _reconciler} =
             start_supervised(
               {Reconciler,
                name: reconciler_name,
                store: second_store,
                registry: second_registry_name,
                guardian_opts: [
                  group_alive_fun: fn ^process_group_id -> Agent.get(alive, & &1) end,
                  process_identity_fun: fn ^process_group_id -> {:ok, :original} end,
                  reap_fun: fn ^process_group_id, {:known, :original} ->
                    send(parent, :recovered_group_reap)
                    Agent.update(alive, fn _ -> false end)
                    {:ok, :reaped}
                  end
                ]}
             )

    assert_receive :recovered_group_reap, 2_000

    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} =
             Ownership.claim(ticket, second_registry_name, store: second_store)

    assert_eventually(fn -> Ownership.current(ticket, second_registry_name) == :none end)
    assert {:ok, replacement} = Ownership.claim(ticket, second_registry_name, store: second_store)
    assert :ok = Ownership.release(replacement, second_registry_name)
  end

  test "a corrupt receipt store fails closed instead of discarding ownership" do
    root = Path.join(System.tmp_dir!(), "ownership-corrupt-#{System.unique_integer([:positive])}")
    store_name = Module.concat(__MODULE__, :CorruptStore)

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(root)
    File.write!(Path.join(root, "workspace-ownership.receipts"), :erlang.term_to_binary(:wrong_format))
    Process.flag(:trap_exit, true)

    assert {:error, {:workspace_ownership_store_unavailable, :invalid_receipt_store}} =
             Store.start_link(name: store_name, state_dir: root, sync_fun: fn -> :ok end)
  end

  test "receipt operations report store loss instead of crashing callers" do
    root = Path.join(System.tmp_dir!(), "ownership-store-loss-#{System.unique_integer([:positive])}")
    store_name = Module.concat(__MODULE__, :StoppedStore)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, store} = Store.start_link(name: store_name, state_dir: root, sync_fun: fn -> :ok end)
    assert :ok = Store.delete("missing-ticket", store)
    :ok = GenServer.stop(store)

    assert {:error, {:store_unavailable, _reason}} = Store.put("ticket", %{phase: :active}, store)
    assert {:error, {:store_unavailable, _reason}} = Store.delete("ticket", store)
    assert {:error, {:store_unavailable, _reason}} = Store.get("ticket", store)
    assert {:error, {:store_unavailable, _reason}} = Store.all(store)
  end

  test "a claim is rejected when its ownership receipt cannot be made durable" do
    root = Path.join(System.tmp_dir!(), "ownership-sync-failure-#{System.unique_integer([:positive])}")
    ticket = "ownership-sync-failure-ticket-#{System.unique_integer([:positive])}"
    store_name = Module.concat(__MODULE__, :FailingStore)
    {:ok, sync_calls} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      File.rm_rf(root)
      if Process.alive?(sync_calls), do: Agent.stop(sync_calls)
    end)

    sync_fun = fn ->
      Agent.get_and_update(sync_calls, fn
        0 -> {:ok, 1}
        count -> {{:error, :disk_full}, count + 1}
      end)
    end

    {:ok, store} = Store.start_link(name: store_name, state_dir: root, sync_fun: sync_fun)

    assert {:error, {:workspace_ownership_unavailable, {:persist_failed, :disk_full}}} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, store: store)

    assert :none = Ownership.current(ticket)
    assert {:ok, %{}} = Store.all(store)
  end

  defp assert_eventually(fun, attempts \\ 80) do
    if fun.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end
end
