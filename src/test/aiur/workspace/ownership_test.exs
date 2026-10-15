defmodule Aiur.Workspace.OwnershipTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.{HostLock, Ownership}
  alias Aiur.Workspace.Ownership.{Guardian, Store}

  test "restored guardian releases its persisted host lock only after provider drainage" do
    ticket = "ownership-restored-host-lock-#{System.unique_integer([:positive])}"
    workspace = Path.join(Aiur.TestSupport.tmp_root!("ownership-restored-host-lock"), ticket)
    parent = self()
    group = System.unique_integer([:positive])
    {:ok, alive} = Agent.start_link(fn -> true end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(alive)
      _ = Store.delete(ticket)
    end)

    assert {:ok, lock} = HostLock.acquire(workspace, ticket, alive_fun: fn _ -> true end)

    receipt = %{
      ticket: ticket,
      generation: 1,
      owner_id: "workspace:1",
      phase: :reaping,
      provider_expected?: true,
      provider: %{process_group_id: group, process_identities: %{{:group, group} => {:known, :restored_group}}},
      provider_cleanup: :unresolved,
      host_lock: lock
    }

    assert {:ok, lease} =
             Guardian.restore(receipt, Aiur.Workspace.Ownership.Registry,
               group_alive_fun: fn ^group -> Agent.get(alive, & &1) end,
               process_identity_fun: fn ^group -> {:ok, :restored_group} end,
               reap_fun: fn ^group ->
                 send(parent, {:restored_host_lock_reap_started, self()})

                 receive do
                   :drain_restored_provider -> :ok
                 end

                 Agent.update(alive, fn _ -> false end)
                 :ok
               end
             )

    guardian = lease.guardian
    monitor = Process.monitor(guardian)
    assert_receive {:restored_host_lock_reap_started, reaper}, 2_000
    assert {:ok, holder} = HostLock.holder(workspace)
    assert holder.owner_id == lock.holder.owner_id
    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)

    send(reaper, :drain_restored_provider)
    assert_eventually(fn -> HostLock.holder(workspace) == :none and Ownership.current(ticket) == :none end)
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 2_000
  end

  test "a generation excludes a competing runner until it releases" do
    ticket = "ownership-#{System.unique_integer([:positive])}"

    assert {:ok, lease} = Ownership.claim(ticket)
    assert {:ok, %{phase: :provisioning}} = Ownership.current(ticket)
    assert {:ok, active_lease} = Ownership.activate(lease)

    contender = Task.async(fn -> Ownership.claim(ticket) end)

    assert {:error, {:workspace_owned, {:ok, %{generation: generation, phase: :active}}}} =
             Task.await(contender)

    assert generation == lease.generation
    assert :ok = Ownership.release(active_lease)
    assert :none = Ownership.current(ticket)
  end

  test "guardian telemetry follows actual containment phases through final release" do
    ticket = "ownership-telemetry-#{System.unique_integer([:positive])}"
    parent = self()
    process_group_id = System.unique_integer([:positive])
    {:ok, group_alive} = Agent.start_link(fn -> true end)
    {:ok, telemetry} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(group_alive)
      Aiur.TestSupport.safe_stop(telemetry)
    end)

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               group_alive_fun: fn group -> group == process_group_id and Agent.get(group_alive, & &1) end,
               process_identity_fun: &test_process_identity/1,
               reap_fun: fn group ->
                 send(parent, {:telemetry_reap, self(), group})

                 receive do
                   :finish_telemetry_reap -> Agent.update(group_alive, fn _ -> false end)
                 end
               end,
               telemetry_fun: fn ownership, boundary, outcome ->
                 Agent.update(telemetry, &[{boundary, outcome, ownership} | &1])
               end
             )

    assert [{:start, :claimed, %{phase: :provisioning}}] = telemetry_events(telemetry)
    assert {:ok, active_lease} = Ownership.activate(lease)
    assert [{:start, :claimed, %{phase: :provisioning}}, {:point, :active, %{phase: :active}}] = telemetry_events(telemetry)
    assert :ok = Ownership.track_process_group(active_lease, process_group_id)

    release = Task.async(fn -> Ownership.release_and_wait(active_lease) end)

    assert_receive {:telemetry_reap, reaper, ^process_group_id}, 2_000

    assert [{:start, :claimed, %{phase: :provisioning}}, {:point, :active, %{phase: :active}}, {:point, :reaping, %{phase: :reaping}}] =
             telemetry_events(telemetry)

    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)
    send(reaper, :finish_telemetry_reap)
    assert {:ok, %{phase: :released}} = Task.await(release, 2_000)

    assert [{:start, :claimed, %{phase: :provisioning}}, {:point, :active, %{phase: :active}}, {:point, :reaping, %{phase: :reaping}}, {:end, :released, %{phase: :released}}] =
             telemetry_events(telemetry)

    assert :none = Ownership.current(ticket)
  end

  test "a crashed runner releases its generation automatically" do
    ticket = "ownership-crash-#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:claimed, Ownership.claim(ticket)})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, {:ok, _lease}}, 2_000
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1000
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
  end

  test "a live generation reports its owner and claim metadata until the owner dies" do
    ticket = "ownership-holder-#{System.unique_integer([:positive])}"
    parent = self()
    holder = %{issue_id: "issue-holder", update_recipient: parent, worker_host: nil}

    owner =
      spawn(fn ->
        send(parent, {:claimed, Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, holder: holder)})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, {:ok, lease}}, 2_000
    assert lease in Ownership.leases()
    assert {:ok, %{owner: ^owner, holder: ^holder}} = Ownership.holder(lease)
    assert {:error, :workspace_ownership_lost} = Ownership.holder(%{lease | generation: lease.generation + 1})

    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1000
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    assert {:error, :workspace_ownership_lost} = Ownership.holder(lease)
    refute Enum.any?(Ownership.leases(), &(&1.ticket == ticket))
  end

  test "brutal runner death retains the lease until its tracked child group is reaped" do
    ticket = "ownership-child-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    parent = self()
    {:ok, child_alive} = Agent.start_link(fn -> true end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(child_alive)
    end)

    group_alive? = fn group -> group == process_group_id and Agent.get(child_alive, & &1) end

    reap = fn group ->
      send(parent, {:reap_started, self(), group})

      receive do
        :finish_reap -> Agent.update(child_alive, fn _ -> false end)
      end

      {:ok, :reaped}
    end

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            reap_fun: reap,
            group_alive_fun: group_alive?,
            process_identity_fun: &test_process_identity/1
          )

        {:ok, active_lease} = Ownership.activate(lease)
        :ok = Ownership.track_process_group(active_lease, process_group_id)
        send(parent, {:tracked_child, active_lease})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:tracked_child, lease}, 2_000
    guardian = lease.guardian
    guardian_monitor = Process.monitor(guardian)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 2_000
    assert_receive {:reap_started, reaper, ^process_group_id}, 2_000
    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)

    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)

    send(reaper, :finish_reap)
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 2_000
    assert :none = Ownership.current(ticket)
  end

  test "a waiter returns and delivers its exact guardian generation" do
    ticket = "ownership-waiter-#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:claimed, Ownership.claim(ticket)})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, {:ok, lease}}, 2_000
    assert {:waiting, guardian, generation} = Ownership.wait_for_release(ticket, self())
    assert guardian == lease.guardian
    assert generation == lease.generation

    Process.exit(owner, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    assert {:ok, replacement} = Ownership.claim(ticket)
    assert replacement.generation > lease.generation
    assert_receive {:workspace_ownership_available, ^ticket, ^guardian, ^generation}, 2_000

    # The prior guardian's notification cannot be reused for a replacement
    # generation. A fresh subscriber acknowledges B before waiting for B.
    assert {:waiting, replacement_guardian, replacement_generation} = Ownership.wait_for_release(ticket, self())
    assert replacement_guardian == replacement.guardian
    assert replacement_generation == replacement.generation
    assert :ok = Ownership.release(replacement)
    assert_receive {:workspace_ownership_available, ^ticket, ^replacement_guardian, ^replacement_generation}, 2_000
  end

  test "brutal death before provider metadata stays fail-closed" do
    ticket = "ownership-provisional-#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} = Ownership.claim(ticket)
        :ok = Ownership.expect_provider(lease)
        send(parent, {:provider_expected, lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:provider_expected, _lease}, 2_000
    Process.exit(owner, :kill)
    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
  end

  test "telemetry failure cannot break workspace containment" do
    ticket = "ownership-telemetry-failure-#{System.unique_integer([:positive])}"

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, telemetry_fun: fn _lease, _boundary, _outcome -> raise "telemetry failed" end)

    assert {:ok, active_lease} = Ownership.activate(lease)
    assert {:ok, %{phase: :released}} = Ownership.release_and_wait(active_lease)
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

  defp test_process_identity(pid), do: {:ok, {:test_process, pid}}

  defp telemetry_events(telemetry), do: Agent.get(telemetry, &Enum.reverse/1)
end
