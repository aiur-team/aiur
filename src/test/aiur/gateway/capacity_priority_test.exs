defmodule Aiur.Gateway.CapacityPriorityTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Gateway.Capacity

  defp start(projects \\ %{"o/a" => 8, "o/b" => 8}) do
    start_supervised!({Capacity, ceiling: 12, projects: projects, priorities: %{"o/a" => 1, "o/b" => 2}})
  end

  # Grants belong to the calling process, so each "orchestrator" is a task that stays alive.
  defp orchestrator(project, issue_ids) do
    parent = self()

    start_supervised!(
      Supervisor.child_spec(
        {Task,
         fn ->
           send(parent, {:acquired, project, Enum.map(issue_ids, &Capacity.acquire(project, &1))})
           receive do: (:stop -> :ok)
         end},
        id: make_ref()
      )
    )

    assert_receive {:acquired, ^project, results}, 1_000
    results
  end

  defp granted(results), do: Enum.count(results, &(&1 == :ok))

  test "saturated: A fills to its max before B, even when B asks first" do
    start()
    Capacity.report_demand("o/a", 10)
    Capacity.report_demand("o/b", 10)

    b = orchestrator("o/b", Enum.to_list(11..20))
    a = orchestrator("o/a", Enum.to_list(1..10))

    assert granted(b) == 4
    assert granted(a) == 8
    assert %{held: 12} = Capacity.snapshot()
  end

  test "A has no ready work: B uses every free slot" do
    start(%{"o/a" => 8, "o/b" => 12})
    Capacity.report_demand("o/a", 0)
    Capacity.report_demand("o/b", 10)

    assert granted(orchestrator("o/b", Enum.to_list(1..10))) == 10
  end

  test "a project that never reported demand does not hold slots back" do
    start()
    Capacity.report_demand("o/b", 10)

    assert granted(orchestrator("o/b", Enum.to_list(1..8))) == 8
  end

  test "B keeps its running agents when A wakes up; A gets the next free slots" do
    start()
    Capacity.report_demand("o/b", 12)
    assert granted(orchestrator("o/b", Enum.to_list(1..8))) == 8

    Capacity.report_demand("o/a", 5)
    assert %{held: 8} = Capacity.snapshot()
    assert granted(orchestrator("o/a", [101, 102, 103, 104, 105])) == 4
    assert %{held: 12} = Capacity.snapshot()
  end
end
