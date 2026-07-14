defmodule Aiur.Workspace.OwnershipTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.Workspace.Ownership

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
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    _registry_state = :sys.get_state(Aiur.Workspace.Ownership.Registry)
    assert :none = Ownership.current(ticket)
  end

  test "brutal runner death retains the lease until its tracked child group is reaped" do
    ticket = "ownership-child-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    parent = self()
    {:ok, child_alive} = Agent.start_link(fn -> true end)

    on_exit(fn ->
      if Process.alive?(child_alive), do: Agent.stop(child_alive)
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
        {:ok, lease} = Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, reap_fun: reap, group_alive_fun: group_alive?)
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

  test "a waiter is acknowledged against its exact guardian and receives a later release" do
    ticket = "ownership-waiter-#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:claimed, Ownership.claim(ticket)})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, {:ok, lease}}, 2_000
    assert :waiting = Ownership.wait_for_release(ticket, self())

    Process.exit(owner, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    assert {:ok, replacement} = Ownership.claim(ticket)
    assert replacement.generation > lease.generation
    assert_receive {:workspace_ownership_available, ^ticket}, 2_000

    # The prior guardian's notification cannot be reused for a replacement
    # generation. A fresh subscriber acknowledges B before waiting for B.
    assert :waiting = Ownership.wait_for_release(ticket, self())
    assert :ok = Ownership.release(replacement)
    assert_receive {:workspace_ownership_available, ^ticket}, 2_000
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

  test "non-Codex root process containment reaps before releasing" do
    ticket = "ownership-root-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, child_alive} = Agent.start_link(fn -> true end)

    on_exit(fn -> if Process.alive?(child_alive), do: Agent.stop(child_alive) end)

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            root_alive_fun: fn pid -> pid == root_pid and Agent.get(child_alive, & &1) end,
            root_reap_fun: fn pid ->
              send(parent, {:root_reap_started, self(), pid})

              receive do
                :finish_root_reap -> Agent.update(child_alive, fn _ -> false end)
              end
            end
          )

        :ok = Ownership.track_provider(lease, %{root_pid: root_pid})
        send(parent, {:root_tracked, lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:root_tracked, %{guardian: guardian}}, 2_000
    Process.exit(owner, :kill)
    assert_receive {:root_reap_started, reaper, ^root_pid}, 2_000
    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)
    send(reaper, :finish_root_reap)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    refute Process.alive?(guardian)
  end

  test "release_and_wait returns only after final registry removal" do
    ticket = "ownership-final-release-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, child_alive} = Agent.start_link(fn -> true end)

    on_exit(fn -> if Process.alive?(child_alive), do: Agent.stop(child_alive) end)

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               root_alive_fun: fn pid -> pid == root_pid and Agent.get(child_alive, & &1) end,
               root_reap_fun: fn pid ->
                 send(parent, {:final_reap_started, self(), pid})

                 receive do
                   :finish_final_reap -> Agent.update(child_alive, fn _ -> false end)
                 end
               end
             )

    :ok = Ownership.track_provider(lease, %{root_pid: root_pid})
    release = Task.async(fn -> Ownership.release_and_wait(lease) end)

    assert_receive {:final_reap_started, reaper, ^root_pid}, 2_000
    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)
    refute Task.yield(release, 100)
    send(reaper, :finish_final_reap)
    assert {:ok, %{phase: :released}} = Task.await(release, 2_000)
    assert :none = Ownership.current(ticket)
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

  test "brutal death during session startup reaps the group registered at spawn" do
    ticket = "ownership-startup-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    parent = self()
    {:ok, child_alive} = Agent.start_link(fn -> true end)

    on_exit(fn ->
      if Process.alive?(child_alive), do: Agent.stop(child_alive)
    end)

    group_alive? = fn group -> group == process_group_id and Agent.get(child_alive, & &1) end

    reap = fn group ->
      send(parent, {:startup_reap_started, self(), group})

      receive do
        :finish_startup_reap -> Agent.update(child_alive, fn _ -> false end)
      end

      {:ok, :reaped}
    end

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            reap_fun: reap,
            group_alive_fun: group_alive?
          )

        send(parent, {:startup_lease, lease})

        callback = fn group ->
          :ok = Ownership.track_process_group(lease, group)
          send(parent, {:startup_group_registered, group})
        end

        SessionLifecycle.start_agent_session(
          "/workspace",
          [backend: "codex", model: nil, on_process_group_started: callback],
          fn _workspace, opts ->
            Keyword.fetch!(opts, :on_process_group_started).(process_group_id)
            send(parent, :startup_session_blocked)

            receive do
              :finish_session_start -> {:ok, %{}}
            end
          end
        )
      end)

    assert_receive {:startup_group_registered, ^process_group_id}, 2_000
    assert_receive :startup_session_blocked, 2_000
    assert_receive {:startup_lease, %{guardian: guardian}}, 2_000

    guardian_monitor = Process.monitor(guardian)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 2_000
    assert_receive {:startup_reap_started, reaper, ^process_group_id}, 2_000
    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)

    send(reaper, :finish_startup_reap)
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 2_000
    assert :none = Ownership.current(ticket)
  end
end
