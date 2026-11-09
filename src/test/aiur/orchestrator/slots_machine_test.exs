defmodule Aiur.Orchestrator.SlotsMachineTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Gateway.Capacity
  alias Aiur.Issue
  alias Aiur.Orchestrator.{MachineGrant, Slots, State}
  alias Aiur.Project
  alias Aiur.Project.Context

  defp project(id), do: %Project{id: id, repo: id, config_path: "/tmp/none", state_root: "/tmp/none"}

  defp holder(project_id, ids) do
    parent = self()

    start_supervised!(
      Supervisor.child_spec(
        {Task,
         fn ->
           Enum.each(ids, &Capacity.acquire(project_id, &1))
           send(parent, :held)
           receive do: (:stop -> :ok)
         end},
        id: make_ref()
      )
    )

    assert_receive :held, 1_000
  end

  defp entry(status, issue_state \\ "in-progress"),
    do: %{control: %{status: status}, worker_host: nil, issue: %Issue{id: "i-#{status}", identifier: "r#{status}", state: issue_state}}

  test "another project's holders shrink available slots below the local limit" do
    start_supervised!({Capacity, ceiling: 4, projects: %{"o/a" => nil, "o/b" => nil}})
    holder("o/b", [1, 2, 3])
    Context.put(project("o/a"))
    state = %State{max_concurrent_agents: 8}

    assert Slots.available_slots(state) == 1
    assert Slots.dispatch_slots_available?(%Issue{id: "x", state: "todo"}, state) == true
  end

  test "a full machine blocks a reserved-priority dispatch too" do
    start_supervised!({Capacity, ceiling: 2, projects: %{"o/a" => nil, "o/b" => nil}})
    holder("o/b", [1, 2])
    Context.put(project("o/a"))
    state = %State{max_concurrent_agents: 8, priority_dispatch_reservations: %{"x" => 8}}

    refute Slots.dispatch_slots_available?(%Issue{id: "x", state: "todo"}, state)
  end

  test "without a project context the machine broker is ignored" do
    start_supervised!({Capacity, ceiling: 1, projects: %{"o/b" => nil}})
    holder("o/b", [1])

    assert Slots.available_slots(%State{max_concurrent_agents: 8}) == 8
  end

  test "holder_ids names the entries used_slots counts and no others" do
    running = %{
      "work" => entry(:working),
      "paused" => entry(:paused),
      "ci" => entry(:paused, "ci-wait"),
      "done" => entry(:completed)
    }

    state = %State{max_concurrent_agents: 8, running: running}
    ids = MachineGrant.holder_ids(state)

    assert Enum.sort(ids) == ["paused", "work"]
    assert length(ids) == Slots.used_slots(state)
  end

  test "a refused acquire starts no worker and returns the state unchanged" do
    start_supervised!({Capacity, ceiling: 1, projects: %{"o/a" => nil, "o/b" => nil}})
    holder("o/b", [1])
    Context.put(project("o/a"))
    state = %State{max_concurrent_agents: 8}

    assert MachineGrant.granted("x", state, fn -> send(self(), :started) && flunk("worker started") end) == state
    refute_received :started
    assert %{held: 1} = Capacity.snapshot()
  end

  test "a granted acquire starts the worker and holds the slot" do
    start_supervised!({Capacity, ceiling: 1, projects: %{"o/a" => nil}})
    Context.put(project("o/a"))

    assert MachineGrant.granted("x", %State{}, fn -> :started end) == :started
    assert %{held: 1} = Capacity.snapshot()
  end

  test "the tick sync releases a slot whose worker has finished" do
    start_supervised!({Capacity, ceiling: 2, projects: %{"o/a" => nil}})
    Context.put(project("o/a"))
    working = %State{running: %{"w" => entry(:working)}}

    assert :ok = MachineGrant.sync(working)
    assert %{held: 1} = Capacity.snapshot()
    assert Capacity.headroom("o/a") == 1

    assert :ok = MachineGrant.sync(%State{})
    assert %{held: 0} = Capacity.snapshot()
    assert Capacity.headroom("o/a") == 2
  end
end
