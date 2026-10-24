defmodule Aiur.Instance.LeaderFenceTest do
  use ExUnit.Case, async: true

  alias Aiur.Instance.LeaderFence
  alias Aiur.Instance.RepositoryLeader

  test "repo-global writes stop before transport when the lease is lost" do
    request = %{method: :post, caller: "landing_watch_merge_group_requeue"}

    result = LeaderFence.run(request, fn -> false end, fn -> flunk("stale write reached transport") end)

    assert result == {:error, {:repository_leader_fence, :not_owner}}
  end

  test "ticket-scoped writes and reads do not use the repository leader fence" do
    calls = [
      %{method: :get, caller: "landing_watch_observation"},
      %{method: :post, caller: "ticket_state_transition"},
      %{method: :post, caller: "main_watch_single_test_rerun"}
    ]

    for request <- Enum.take(calls, 2) do
      assert :sent = LeaderFence.run(request, fn -> false end, fn -> :sent end)
    end

    rerun = List.last(calls)

    assert {:error, {:repository_leader_fence, :not_owner}} =
             LeaderFence.run(rerun, fn -> false end, fn -> :sent end)
  end

  test "global services stop after a lost lease and start after takeover" do
    suffix = System.unique_integer([:positive])
    supervisor = Module.concat(__MODULE__, "Services#{suffix}")
    leader = Module.concat(__MODULE__, "Leader#{suffix}")
    {:ok, dynamic} = DynamicSupervisor.start_link(strategy: :one_for_one, name: supervisor)
    on_exit(fn -> safe_stop(dynamic) end)

    {:ok, election} = Agent.start_link(fn -> %{claim: :acquired, renew: :ok} end)
    on_exit(fn -> safe_stop(election) end)

    {:ok, pid} =
      RepositoryLeader.start_link(
        name: leader,
        role: "primary",
        repository: "owner/repo",
        services: [__MODULE__.TestService],
        supervisor: supervisor,
        interval_ms: 60_000,
        store_configured_fun: fn -> true end,
        claim_fun: fn _, _ -> Agent.get(election, & &1.claim) end,
        renew_fun: fn _, _ -> Agent.get(election, & &1.renew) end
      )

    on_exit(fn -> safe_stop(pid) end)
    assert_eventually(fn -> length(DynamicSupervisor.which_children(supervisor)) == 1 end)

    Agent.update(election, &%{&1 | claim: :held, renew: {:error, :lease_lost}})
    send(pid, :elect)
    assert_eventually(fn -> DynamicSupervisor.which_children(supervisor) == [] end)

    Agent.update(election, &%{&1 | claim: :acquired})
    send(pid, :elect)
    assert_eventually(fn -> length(DynamicSupervisor.which_children(supervisor)) == 1 end)
  end

  defp assert_eventually(assertion, attempts \\ 100)
  defp assert_eventually(assertion, 0), do: assert(assertion.())

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defmodule TestService do
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, nil}
  end
end
