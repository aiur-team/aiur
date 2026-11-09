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

    spawn(fn ->
      Enum.each(ids, &Capacity.acquire(project_id, &1))
      send(parent, :held)
      Process.sleep(:infinity)
    end)

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
end
