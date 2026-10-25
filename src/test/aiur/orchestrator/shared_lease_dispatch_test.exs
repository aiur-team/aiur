defmodule Aiur.Orchestrator.SharedLeaseDispatchTest do
  use Aiur.DispatcherTestSupport

  alias Aiur.Instance.LeaseStore
  alias Aiur.Orchestrator.{Dispatcher, State}
  alias Aiur.TestSupport.Isolation

  test "two dispatcher instances race through launch and start only one runner" do
    parent = self()
    {:ok, leases} = Agent.start_link(fn -> MapSet.new() end)
    on_exit(fn -> if Process.alive?(leases), do: Agent.stop(leases) end)

    claim_fun = fn issue ->
      {:ok, key} = LeaseStore.ticket_key(issue)
      send(parent, {:lease_claimed, key})

      Agent.get_and_update(leases, fn held ->
        if MapSet.member?(held, key),
          do: {:held, held},
          else: {:acquired, MapSet.put(held, key)}
      end)
    end

    issue = %Aiur.Issue{
      id: "42",
      identifier: "42",
      tracker_identity: %Aiur.TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "Acme",
        repository: "Widgets",
        provider_id: "issue-node-42",
        identifier: "42",
        reason: nil
      },
      state: "todo",
      selected_backend: "codex"
    }

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Dispatcher.do_dispatch_issue(
            %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
            issue,
            nil,
            nil,
            lease_claim_fun: claim_fun,
            runner: fn dispatched, _, _ ->
              send(parent, {:runner_started, dispatched.id})
              :ok
            end
          )
        end)
      end

    states = Enum.map(tasks, &Task.await(&1, 2_000))

    assert_receive {:lease_claimed, "acme/widgets#42"}, 1_000
    assert_receive {:lease_claimed, "acme/widgets#42"}, 1_000
    assert Enum.count(states, &MapSet.member?(&1.claimed, issue.id)) == 1
    assert_receive {:runner_started, "42"}, 1_000
    refute_receive {:runner_started, "42"}, 100
  end

  test "a second dispatcher takes the lease after the first worker dies and the lease expires" do
    parent = self()
    ttl_ms = 30_000
    grace_ms = 20_000
    issue = lease_issue("44")
    {:ok, store} = Agent.start_link(fn -> %{now: 0, leases: %{}} end)
    on_exit(fn -> if Process.alive?(store), do: Agent.stop(store) end)

    claim_for = fn instance_id ->
      fn ticket ->
        {:ok, key} = LeaseStore.ticket_key(ticket)

        Agent.get_and_update(store, fn state ->
          case Map.get(state.leases, key) do
            %{expires_at: expiry} when state.now < expiry + grace_ms ->
              {:held, state}

            _expired_or_unheld ->
              lease = %{instance_id: instance_id, expires_at: state.now + ttl_ms}
              {:acquired, put_in(state.leases[key], lease)}
          end
        end)
      end
    end

    start_worker = fn instance_id ->
      fn _issue, _runner, _recipient, _context, _opts ->
        worker =
          Isolation.start_owned!(
            {Task,
             fn ->
               send(parent, {:runner_started, instance_id, self()})
               receive do: (:stop -> :ok)
             end}
          )

        {:ok, worker}
      end
    end

    first_state = dispatch_instance(issue, claim_for.("first"), start_worker.("first"))
    assert_receive {:runner_started, "first", first_worker}, 1_000
    assert MapSet.member?(first_state.claimed, issue.id)

    held_state = dispatch_instance(issue, claim_for.("second"), start_worker.("second"))
    refute MapSet.member?(held_state.claimed, issue.id)
    refute_receive {:runner_started, "second", _worker}, 100

    first_monitor = Process.monitor(first_worker)
    Process.exit(first_worker, :kill)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, :killed}, 1_000

    Agent.update(store, &%{&1 | now: ttl_ms + grace_ms + 1})
    second_state = dispatch_instance(issue, claim_for.("second"), start_worker.("second"))

    assert MapSet.member?(second_state.claimed, issue.id)
    assert_receive {:runner_started, "second", second_worker}, 1_000
    Process.exit(second_worker, :kill)
  end

  test "dispatch eligibility is checked before acquiring the shared lease" do
    parent = self()
    issue = %{issue("held-before-lease") | selected_backend: "codex"}

    Process.put({Aiur.Handoff, :dispatch_hold}, true)

    state =
      try do
        Dispatcher.do_dispatch_issue(
          %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
          issue,
          nil,
          nil,
          lease_claim_fun: fn _ ->
            send(parent, :lease_claimed)
            :acquired
          end,
          runner: fn _, _, _ -> :ok end
        )
      after
        Process.delete({Aiur.Handoff, :dispatch_hold})
      end

    refute_receive :lease_claimed, 0
    refute MapSet.member?(state.claimed, issue.id)
  end

  test "an owned ticket reaches the lease only on its live owner" do
    parent = self()

    roster = [
      %{instance_id: "nuc", metadata: %{"version" => 1, "data" => %{"owns" => [%{"label" => "build-lane:voice"}], "pool" => true, "dispatching" => true}}},
      %{instance_id: "pc", metadata: %{"version" => 1, "data" => %{"owns" => [], "pool" => true, "dispatching" => true}}}
    ]

    issue = %{lease_issue("voice-42") | labels: ["build-lane:voice"]}

    for instance_id <- ["nuc", "pc"] do
      Dispatcher.do_dispatch_issue(
        %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
        issue,
        nil,
        nil,
        ownership_instance_id: instance_id,
        ownership_live_instances_fun: fn -> {:ok, roster} end,
        lease_claim_fun: fn _ ->
          send(parent, {:lease_attempt, instance_id})
          :acquired
        end,
        runner: fn _, _, _ -> :ok end
      )
    end

    assert_receive {:lease_attempt, "nuc"}, 1_000
    refute_receive {:lease_attempt, "pc"}, 100
  end

  test "an unknown live roster blocks before attempting the shared lease" do
    parent = self()
    issue = %{lease_issue("voice-43") | labels: ["build-lane:voice"]}

    state =
      Dispatcher.do_dispatch_issue(
        %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
        issue,
        nil,
        nil,
        ownership_live_instances_fun: fn -> {:error, :offline} end,
        lease_claim_fun: fn _ ->
          send(parent, :lease_attempt)
          :acquired
        end,
        runner: fn _, _, _ ->
          send(parent, :runner_started)
          :ok
        end
      )

    refute_receive :lease_attempt, 0
    refute_receive :runner_started, 0
    refute MapSet.member?(state.claimed, issue.id)
  end

  test "a lease acquired for a launch that cannot start is released" do
    parent = self()

    issue = %Aiur.Issue{
      id: "43",
      identifier: "43",
      tracker_identity: %Aiur.TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "Acme",
        repository: "Widgets",
        provider_id: "issue-node-43",
        identifier: "43",
        reason: nil
      },
      state: "todo",
      selected_backend: "codex"
    }

    state =
      Dispatcher.do_dispatch_issue(
        %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
        issue,
        nil,
        nil,
        lease_claim_fun: fn _ -> :acquired end,
        lease_release_fun: fn ticket ->
          send(parent, {:lease_released, ticket})
          :ok
        end,
        start_runner_task_fun: fn _issue, _runner, _recipient, _context, _opts ->
          {:error, :controlled_spawn_failure}
        end
      )

    assert_receive {:lease_released, ^issue}, 1_000
    refute MapSet.member?(state.claimed, issue.id)
  end

  defp dispatch_instance(issue, claim_fun, start_worker_fun) do
    Dispatcher.do_dispatch_issue(
      %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
      issue,
      nil,
      nil,
      lease_claim_fun: claim_fun,
      start_runner_task_fun: start_worker_fun
    )
  end

  defp lease_issue(number) do
    %Aiur.Issue{
      id: number,
      identifier: number,
      tracker_identity: %Aiur.TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "Acme",
        repository: "Widgets",
        provider_id: "issue-node-#{number}",
        identifier: number,
        reason: nil
      },
      state: "todo",
      selected_backend: "codex"
    }
  end
end
