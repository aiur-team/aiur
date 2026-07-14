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

    assert_receive {:claimed, {:ok, _lease}}
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
