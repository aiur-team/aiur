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

  test "guardian telemetry follows actual containment phases through final release" do
    ticket = "ownership-telemetry-#{System.unique_integer([:positive])}"
    parent = self()
    process_group_id = System.unique_integer([:positive])
    {:ok, group_alive} = Agent.start_link(fn -> true end)

    on_exit(fn ->
      if Process.alive?(group_alive), do: Agent.stop(group_alive)
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
                 send(parent, {:ownership_telemetry, boundary, outcome, ownership})
               end
             )

    assert_receive {:ownership_telemetry, :start, :claimed, %{phase: :provisioning}}
    assert {:ok, active_lease} = Ownership.activate(lease)
    assert_receive {:ownership_telemetry, :point, :active, %{phase: :active}}
    assert :ok = Ownership.track_process_group(active_lease, process_group_id)

    release = Task.async(fn -> Ownership.release_and_wait(active_lease) end)

    assert_receive {:ownership_telemetry, :point, :reaping, %{phase: :reaping}}
    assert_receive {:telemetry_reap, reaper, ^process_group_id}
    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)
    send(reaper, :finish_telemetry_reap)
    assert {:ok, %{phase: :released}} = Task.await(release, 2_000)
    assert_receive {:ownership_telemetry, :end, :released, %{phase: :released}}
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

  test "release_and_wait retains an expected provider when containment and cleanup are unavailable" do
    ticket = "ownership-unidentified-provider-#{System.unique_integer([:positive])}"
    assert {:ok, lease} = Ownership.claim(ticket)
    assert :ok = Ownership.expect_provider(lease)

    cleanup = Task.async(fn -> Ownership.release_and_wait(lease) end)

    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    refute Task.yield(cleanup, 100)
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
    Task.shutdown(cleanup, :brutal_kill)
  end

  test "releases an exact-generation expectation cancelled before provider spawn" do
    ticket = "ownership-cancelled-expectation-#{System.unique_integer([:positive])}"
    assert {:ok, lease} = Ownership.claim(ticket)
    assert :ok = Ownership.expect_provider(lease)
    assert :ok = Ownership.cancel_provider_expectation(lease)
    assert {:ok, %{phase: :released}} = Ownership.release_and_wait(lease)
    assert :none = Ownership.current(ticket)
  end

  test "rejects stale provider registration instead of acknowledging a lost lease" do
    ticket = "ownership-stale-provider-#{System.unique_integer([:positive])}"
    assert {:ok, lease} = Ownership.claim(ticket)

    stale = %{lease | generation: lease.generation + 1}

    assert {:error, :workspace_ownership_lost} = Ownership.expect_provider(stale)
    assert {:error, :workspace_ownership_lost} = Ownership.track_provider(stale, %{root_pid: 42})
    assert {:error, :workspace_ownership_lost} = Ownership.expect_provider(nil)
    assert {:error, :workspace_ownership_lost} = Ownership.track_provider(nil, %{root_pid: 42})

    assert :ok = Ownership.release(lease)
  end

  test "remote ownership remains fail-closed when its owner dies" do
    ticket = "ownership-remote-recovery-#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry)

        :ok = Ownership.track_provider(lease, %{remote: true})
        send(parent, {:remote_provider_tracked, lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:remote_provider_tracked, _lease}, 2_000
    Process.exit(owner, :kill)

    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    Process.sleep(150)
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
            process_identity_fun: &test_process_identity/1,
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

  test "non-Codex containment reaps a recorded child after its root already died" do
    ticket = "ownership-recorded-child-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    child_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, alive} = Agent.start_link(fn -> %{root_pid => false, child_pid => true} end)

    on_exit(fn ->
      if Process.alive?(alive), do: Agent.stop(alive)
    end)

    process_alive? = fn pid -> Agent.get(alive, &Map.fetch!(&1, pid)) end

    process_reap = fn pid ->
      send(parent, {:recorded_process_reap, self(), pid})

      receive do
        :finish_recorded_reap -> Agent.update(alive, &Map.put(&1, pid, false))
      end

      :ok
    end

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            process_alive_fun: process_alive?,
            process_identity_fun: &test_process_identity/1,
            process_reap_fun: process_reap
          )

        :ok = Ownership.track_provider(lease, %{root_pid: root_pid, descendant_pids: [child_pid]})
        send(parent, {:recorded_child_tracked, lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:recorded_child_tracked, _lease}, 2_000
    Process.exit(owner, :kill)
    assert_receive {:recorded_process_reap, reaper, ^child_pid}, 2_000
    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)

    send(reaper, :finish_recorded_reap)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
  end

  test "reaps recorded descendants after a process group leader exits" do
    ticket = "ownership-gone-group-leader-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    child_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, child_alive} = Agent.start_link(fn -> true end)

    on_exit(fn ->
      if Process.alive?(child_alive), do: Agent.stop(child_alive)
    end)

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            group_alive_fun: fn ^process_group_id -> true end,
            process_alive_fun: fn ^child_pid -> Agent.get(child_alive, & &1) end,
            process_identity_fun: fn
              ^process_group_id -> :gone
              ^child_pid -> {:ok, :recorded_child}
            end,
            reap_fun: fn group -> send(parent, {:unexpected_group_reap, group}) end,
            process_reap_fun: fn pid, identity ->
              send(parent, {:recorded_descendant_reap, self(), pid, identity})

              receive do
                :finish_recorded_descendant_reap -> Agent.update(child_alive, fn _ -> false end)
              end
            end
          )

        :ok =
          Ownership.track_provider(lease, %{
            process_group_id: process_group_id,
            descendant_pids: [child_pid]
          })

        send(parent, :gone_group_leader_tracked)
        Process.sleep(:infinity)
      end)

    assert_receive :gone_group_leader_tracked, 2_000
    Process.exit(owner, :kill)

    assert_receive {:recorded_descendant_reap, reaper, ^child_pid, {:known, :recorded_child}}, 500
    refute_receive {:unexpected_group_reap, ^process_group_id}, 0

    send(reaper, :finish_recorded_descendant_reap)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
  end

  test "does not reap a process group after its identifier is reused" do
    ticket = "ownership-reused-group-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    parent = self()
    {:ok, identities} = Agent.start_link(fn -> %{process_group_id => :original} end)

    on_exit(fn ->
      if Process.alive?(identities), do: Agent.stop(identities)
    end)

    identity_fun = fn pid -> {:ok, Agent.get(identities, &Map.fetch!(&1, pid))} end

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            group_alive_fun: fn ^process_group_id -> true end,
            process_identity_fun: identity_fun,
            reap_fun: fn group -> send(parent, {:unexpected_group_reap, group}) end
          )

        :ok = Ownership.track_process_group(lease, process_group_id)
        send(parent, :reused_group_tracked)
        Process.sleep(:infinity)
      end)

    assert_receive :reused_group_tracked, 2_000
    Agent.update(identities, &Map.put(&1, process_group_id, :replacement))
    Process.exit(owner, :kill)

    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    refute_receive {:unexpected_group_reap, ^process_group_id}, 100
  end

  test "revalidates the captured group identity at the signal boundary" do
    ticket = "ownership-reap-barrier-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    parent = self()
    {:ok, identities} = Agent.start_link(fn -> :original end)

    on_exit(fn -> if Process.alive?(identities), do: Agent.stop(identities) end)

    identity_fun = fn ^process_group_id -> {:ok, Agent.get(identities, & &1)} end

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            group_alive_fun: fn ^process_group_id -> true end,
            process_identity_fun: identity_fun,
            reap_fun: fn group, expected_identity ->
              send(parent, {:signal_barrier, self(), group, expected_identity})

              receive do
                :continue_signal ->
                  if expected_identity == {:known, Agent.get(identities, & &1)},
                    do: send(parent, {:unexpected_group_signal, group}),
                    else: send(parent, {:reused_group_protected, group})
              end
            end
          )

        :ok = Ownership.track_process_group(lease, process_group_id)
        send(parent, :barrier_group_tracked)
        Process.sleep(:infinity)
      end)

    assert_receive :barrier_group_tracked, 2_000
    Process.exit(owner, :kill)
    assert_receive {:signal_barrier, reaper, ^process_group_id, {:known, :original}}, 2_000
    Agent.update(identities, fn _ -> :replacement end)
    send(reaper, :continue_signal)
    assert_receive {:reused_group_protected, ^process_group_id}, 2_000
    refute_receive {:unexpected_group_signal, ^process_group_id}, 100
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
  end

  test "does not reap a root process after its identifier is reused" do
    ticket = "ownership-reused-root-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, identities} = Agent.start_link(fn -> %{root_pid => :original} end)

    on_exit(fn ->
      if Process.alive?(identities), do: Agent.stop(identities)
    end)

    identity_fun = fn pid -> {:ok, Agent.get(identities, &Map.fetch!(&1, pid))} end

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            root_alive_fun: fn ^root_pid -> true end,
            process_identity_fun: identity_fun,
            root_reap_fun: fn pid -> send(parent, {:unexpected_root_reap, pid}) end
          )

        :ok = Ownership.track_provider(lease, %{root_pid: root_pid})
        send(parent, :reused_root_tracked)
        Process.sleep(:infinity)
      end)

    assert_receive :reused_root_tracked, 2_000
    Agent.update(identities, &Map.put(&1, root_pid, :replacement))
    Process.exit(owner, :kill)

    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    refute_receive {:unexpected_root_reap, ^root_pid}, 100
  end

  test "releases a gone root identity without signaling" do
    ticket = "ownership-gone-root-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    parent = self()

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               root_alive_fun: fn ^root_pid -> false end,
               process_identity_fun: fn ^root_pid -> :gone end,
               root_reap_fun: fn pid -> send(parent, {:unexpected_root_reap, pid}) end
             )

    assert :ok = Ownership.track_provider(lease, %{root_pid: root_pid})

    assert {:ok, %{phase: :released}} = Ownership.release_and_wait(lease)
    assert :none = Ownership.current(ticket)
    refute_receive {:unexpected_root_reap, ^root_pid}, 100
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
               process_identity_fun: &test_process_identity/1,
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

  defp test_process_identity(pid), do: {:ok, {:test_process, pid}}

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
            group_alive_fun: group_alive?,
            process_identity_fun: &test_process_identity/1
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
