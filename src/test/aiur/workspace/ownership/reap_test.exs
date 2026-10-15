defmodule Aiur.Workspace.Ownership.ReapTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Ownership

  test "non-Codex root process containment reaps before releasing" do
    ticket = "ownership-root-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, child_alive} = Agent.start_link(fn -> true end)

    on_exit(fn -> Aiur.TestSupport.safe_stop(child_alive) end)

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

  test "brutal no-group death retains the lease after reaping a recorded child" do
    ticket = "ownership-recorded-child-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    child_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, alive} = Agent.start_link(fn -> %{root_pid => false, child_pid => true} end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(alive)
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
    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
  end

  test "brutal no-group death retains a late unrecorded escaped child" do
    ticket = "ownership-late-root-descendant-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    late_child_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, alive} = Agent.start_link(fn -> %{root_pid => false, late_child_pid => true} end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(alive)
    end)

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            process_alive_fun: fn pid -> Agent.get(alive, &Map.fetch!(&1, pid)) end,
            process_identity_fun: &test_process_identity/1
          )

        # The startup snapshot contains only the root. The late child is
        # reparented before this guardian sees it.
        :ok = Ownership.track_provider(lease, %{root_pid: root_pid, descendant_pids: [root_pid]})
        send(parent, :late_root_descendant_tracked)
        Process.sleep(:infinity)
      end)

    assert_receive :late_root_descendant_tracked, 2_000
    Process.exit(owner, :kill)

    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
  end

  test "narrower provider refresh retains every observed descendant" do
    ticket = "ownership-descendant-union-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    escaped_child_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, alive} = Agent.start_link(fn -> %{root_pid => false, escaped_child_pid => true} end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(alive)
    end)

    process_reap = fn pid ->
      send(parent, {:escaped_child_reap, self(), pid})

      receive do
        :finish_escaped_child_reap -> Agent.update(alive, &Map.put(&1, pid, false))
      end

      :ok
    end

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               process_alive_fun: fn pid -> Agent.get(alive, &Map.fetch!(&1, pid)) end,
               process_identity_fun: &test_process_identity/1,
               process_reap_fun: process_reap
             )

    :ok = Ownership.track_provider(lease, %{root_pid: root_pid, descendant_pids: [root_pid, escaped_child_pid]})
    :ok = Ownership.track_provider(lease, %{root_pid: root_pid, descendant_pids: [root_pid]})

    release = Task.async(fn -> Ownership.release_and_wait(lease) end)

    assert_receive {:escaped_child_reap, reaper, ^escaped_child_pid}, 2_000
    send(reaper, :finish_escaped_child_reap)
    assert {:ok, %{phase: :released}} = Task.await(release, 2_000)
    assert :none = Ownership.current(ticket)
  end

  test "reaps recorded descendants after a process group leader exits" do
    ticket = "ownership-gone-group-leader-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    child_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, child_alive} = Agent.start_link(fn -> true end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(child_alive)
    end)

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            group_alive_fun: fn ^process_group_id -> Agent.get(child_alive, & &1) end,
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

  test "retains a group with an unrecorded late descendant after reaping recorded descendants" do
    ticket = "ownership-late-group-descendant-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    recorded_child_pid = System.unique_integer([:positive])
    late_child_pid = System.unique_integer([:positive])
    parent = self()
    {:ok, alive} = Agent.start_link(fn -> %{recorded_child_pid => true, late_child_pid => true} end)
    {:ok, group_identity} = Agent.start_link(fn -> :original end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(alive)
      Aiur.TestSupport.safe_stop(group_identity)
    end)

    process_identity_fun = fn
      ^process_group_id ->
        case Agent.get(group_identity, & &1) do
          :gone -> :gone
          identity -> {:ok, identity}
        end

      ^recorded_child_pid ->
        {:ok, :recorded_child}
    end

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               group_alive_fun: fn ^process_group_id -> Agent.get(alive, &Map.fetch!(&1, late_child_pid)) end,
               process_alive_fun: fn ^recorded_child_pid -> Agent.get(alive, &Map.fetch!(&1, recorded_child_pid)) end,
               process_identity_fun: process_identity_fun,
               process_reap_fun: fn pid, identity ->
                 send(parent, {:late_group_recorded_reap, self(), pid, identity})

                 receive do
                   :finish_late_group_recorded_reap -> Agent.update(alive, &Map.put(&1, recorded_child_pid, false))
                 end
               end
             )

    :ok =
      Ownership.track_provider(lease, %{
        process_group_id: process_group_id,
        descendant_pids: [recorded_child_pid]
      })

    Agent.update(group_identity, fn _ -> :gone end)
    release = Task.async(fn -> Ownership.release_and_wait(lease) end)

    assert_receive {:late_group_recorded_reap, reaper, ^recorded_child_pid, {:known, :recorded_child}}, 500
    send(reaper, :finish_late_group_recorded_reap)

    refute Task.yield(release, 100)
    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)

    Agent.update(alive, &Map.put(&1, late_child_pid, false))
    assert {:ok, %{phase: :released}} = Task.await(release, 2_500)
  end

  test "reaps escaped recorded descendants after groups are gone or reused" do
    for group_state <- [:gone, :replacement] do
      ticket = "ownership-escaped-child-#{group_state}-#{System.unique_integer([:positive])}"
      process_group_id = System.unique_integer([:positive])
      child_pid = System.unique_integer([:positive])
      parent = self()
      {:ok, child_alive} = Agent.start_link(fn -> true end)
      {:ok, group_identity} = Agent.start_link(fn -> :original end)

      on_exit(fn ->
        Aiur.TestSupport.safe_stop(child_alive)
        Aiur.TestSupport.safe_stop(group_identity)
      end)

      process_identity_fun = fn
        ^process_group_id ->
          case Agent.get(group_identity, & &1) do
            :gone -> :gone
            identity -> {:ok, identity}
          end

        ^child_pid ->
          {:ok, :escaped_child}
      end

      assert {:ok, lease} =
               Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
                 group_alive_fun: fn ^process_group_id -> false end,
                 process_alive_fun: fn ^child_pid -> Agent.get(child_alive, & &1) end,
                 process_identity_fun: process_identity_fun,
                 process_reap_fun: fn pid, identity ->
                   send(parent, {:escaped_child_reap, self(), pid, identity})

                   receive do
                     :finish_escaped_child_reap -> Agent.update(child_alive, fn _ -> false end)
                   end
                 end
               )

      :ok =
        Ownership.track_provider(lease, %{
          process_group_id: process_group_id,
          descendant_pids: [child_pid]
        })

      Agent.update(group_identity, fn _ -> group_state end)
      release = Task.async(fn -> Ownership.release_and_wait(lease) end)

      assert_receive {:escaped_child_reap, reaper, ^child_pid, {:known, :escaped_child}}, 500
      send(reaper, :finish_escaped_child_reap)
      assert {:ok, %{phase: :released}} = Task.await(release, 2_000)
    end
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
