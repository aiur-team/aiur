defmodule Aiur.Workspace.Ownership.ReapIdentityTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.Workspace.Ownership

  test "does not reap a process group after its identifier is reused" do
    ticket = "ownership-reused-group-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    parent = self()
    {:ok, identities} = Agent.start_link(fn -> %{process_group_id => :original} end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(identities)
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

    on_exit(fn -> Aiur.TestSupport.safe_stop(identities) end)

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
      Aiur.TestSupport.safe_stop(identities)
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

    on_exit(fn -> Aiur.TestSupport.safe_stop(child_alive) end)

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

  test "brutal death during session startup reaps the group registered at spawn" do
    ticket = "ownership-startup-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    parent = self()
    {:ok, child_alive} = Agent.start_link(fn -> true end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(child_alive)
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
end
