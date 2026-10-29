defmodule Aiur.Workspace.Ownership.RetentionOrderTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.Guardian
  alias Aiur.Workspace.Ownership.{Retention, Store}

  test "retries receipt persistence on a repeated retention mark" do
    ticket = "ownership-retention-retry-#{System.unique_integer([:positive])}"
    root = Aiur.TestSupport.tmp_root!("ownership-retention-retry")
    {:ok, sync_control} = Agent.start_link(fn -> false end)

    sync_fun = fn ->
      Agent.get_and_update(sync_control, fn
        true -> {{:error, :disk_full}, false}
        false -> {:ok, false}
      end)
    end

    {:ok, store} = Store.start_link(name: nil, state_dir: root, sync_fun: sync_fun)
    registry = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    {:ok, registry_pid} = Registry.start_link(keys: :unique, name: registry)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)
      Aiur.TestSupport.safe_stop(registry_pid)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    lease = %{
      ticket: ticket,
      generation: 1,
      owner_id: self(),
      phase: :reaping,
      retained_cause: "provider_unrecorded",
      retained_since: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:ok, _} = Registry.register(registry, ticket, lease)
    assert :ok = Store.put(ticket, %{"retained_cause" => "provider_unrecorded", phase: :active}, store)
    Agent.update(sync_control, fn _ -> true end)

    state = %{
      registry: registry,
      lease: lease,
      store: store,
      provider_expected?: false,
      provider: nil,
      provider_cleanup: nil,
      provider_scope: :unknown,
      provider_boot_id: nil,
      host_lock: nil
    }

    assert %{lease: %{phase: :reaping}} = Retention.mark(state)
    assert {:ok, %{phase: :active}} = Store.get(ticket, store)

    assert %{lease: %{phase: :reaping}} = Retention.mark(state)
    assert {:ok, %{"retained_cause" => "provider_unrecorded", phase: :reaping}} = Store.get(ticket, store)
  end

  test "publishes the reaping phase before retention alert I/O completes" do
    ticket = "ownership-retention-order-#{System.unique_integer([:positive])}"
    parent = self()

    alert_fun = fn topic, _opts ->
      send(parent, {:retention_alert_started, topic})

      receive do
        :finish_retention_alert -> :ok
      end
    end

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, retention_alert_fun: alert_fun)

    assert :ok = Ownership.expect_provider(lease)
    release = Task.async(fn -> Ownership.release_and_wait(lease) end)

    assert_receive {:retention_alert_started, "ticket." <> ^ticket <> ".workspace.workspace_lease_retained"}, 2_000
    assert {:ok, %{phase: :reaping, retained_cause: "provider_unrecorded"}} = Ownership.current(ticket)
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
    refute Task.yield(release, 0)

    send(lease.guardian, :finish_retention_alert)
    Task.shutdown(release, :brutal_kill)
    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    assert :ok = Store.delete(ticket)
  end

  test "persists a changed retention cause after a failed reboot audit" do
    ticket = "ownership-retention-cause-#{System.unique_integer([:positive])}"
    {:ok, boot} = Agent.start_link(fn -> "boot-before" end)
    {:ok, guardians} = Agent.start_link(fn -> [] end)
    Process.unlink(boot)
    Process.unlink(guardians)

    on_exit(fn ->
      Enum.each(Agent.get(guardians, & &1), &Process.exit(&1, :kill))
      _ = Store.delete(ticket)
      Aiur.TestSupport.safe_stop(boot)
      Aiur.TestSupport.safe_stop(guardians)
    end)

    boot_id_fun = fn -> Agent.get(boot, &{:ok, &1}) end
    audit_fun = fn _record -> {:error, :disk_full} end

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               host_boot_id_fun: boot_id_fun,
               audit_fun: audit_fun
             )

    Agent.update(guardians, &[lease.guardian | &1])
    assert :ok = Ownership.expect_provider(lease, :local)
    assert {:ok, receipt} = Store.get(ticket)
    assert :ok = Store.put(ticket, Map.put(receipt, "retained_cause", "provider_unrecorded"))

    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    Agent.update(boot, fn _ -> "boot-after" end)

    assert {:ok, restored} =
             Guardian.restore(Store.get(ticket) |> elem(1), Aiur.Workspace.Ownership.Registry,
               host_boot_id_fun: boot_id_fun,
               audit_fun: audit_fun
             )

    Agent.update(guardians, &[restored.guardian | &1])

    assert_eventually(fn ->
      match?({:ok, %{phase: :reaping, retained_cause: "recovery_audit_failed"}}, Ownership.current(ticket))
    end)

    assert_eventually(fn ->
      match?({:ok, %{"retained_cause" => "recovery_audit_failed"}}, Store.get(ticket))
    end)

    Process.exit(restored.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
  end

  defp assert_eventually(fun, attempts \\ 40) do
    if fun.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end
end
