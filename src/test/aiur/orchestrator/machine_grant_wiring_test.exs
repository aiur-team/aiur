defmodule Aiur.Orchestrator.MachineGrantWiringTest do
  # Drives the real launch and tick paths, so deleting the MachineGrant wiring in either fails here.
  use Aiur.TestSupport, async: false

  alias Aiur.Gateway.Capacity
  alias Aiur.Orchestrator.{Dispatcher, Lifecycle, MachineGrant, State}
  alias Aiur.Project
  alias Aiur.Project.Context

  defp project(id), do: %Project{id: id, repo: id, config_path: "/tmp/none", state_root: "/tmp/none"}

  test "a launch refused by a full machine starts no worker and claims nothing" do
    start_supervised!({Capacity, ceiling: 1, projects: %{"o/a" => nil, "o/b" => nil}})
    assert Capacity.acquire("o/b", 1) == :ok
    Context.put(project("o/a"))
    parent = self()
    issue = %Aiur.Issue{id: "7", identifier: "7", title: "t", state: "todo", selected_backend: "codex"}
    state = %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}

    next = Dispatcher.do_dispatch_issue(state, issue, nil, nil, runner: fn _, _, _ -> send(parent, :runner_started) end, rework_head_sha: nil)

    refute_receive :runner_started, 200
    assert next.running == %{}
    assert {next.claimed, next.retry_attempts} == {state.claimed, state.retry_attempts}
  end

  test "handle_tick releases the slot of a holder that is no longer running" do
    start_supervised!({Capacity, ceiling: 2, projects: %{"o/a" => nil}})
    Context.put(project("o/a"))
    assert Capacity.acquire("o/a", "gone") == :ok
    assert %{held: 1} = Capacity.snapshot()

    assert {:noreply, _} = Lifecycle.handle_tick(%State{})

    assert %{held: 0} = Capacity.snapshot()
  end

  test "report_demand counts A's ready work while B fills the machine, so A gets the next freed slot" do
    start_supervised!({Capacity, ceiling: 1, projects: %{"o/a" => nil, "o/b" => nil}, priorities: %{"o/a" => 1, "o/b" => 2}})
    holder = self()

    {:ok, b} =
      Task.start_link(fn ->
        send(holder, {:b, Capacity.acquire("o/b", 1)})
        receive do: (:release -> :ok)
      end)

    assert_receive {:b, :ok}, 1_000
    Context.put(project("o/a"))
    state = %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}
    issue = %Aiur.Issue{id: "7", identifier: "7", title: "t", state: "todo", selected_backend: "codex"}

    assert ^state = MachineGrant.report_demand(state, [issue])

    # B's slot frees; B asks again and must yield to A's reported demand.
    assert Capacity.sync("o/b", []) == :ok
    assert Capacity.acquire("o/b", 2) == {:error, :yielded}
    send(b, :release)
  end
end
