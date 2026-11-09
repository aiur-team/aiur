defmodule Aiur.Gateway.CapacityTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Gateway.Capacity

  # Each "orchestrator" is a process, because grants are tied to the caller.
  defp orchestrator(project, issue_ids) do
    parent = self()

    pid =
      spawn(fn ->
        results = Enum.map(issue_ids, &Capacity.acquire(project, &1))
        send(parent, {:acquired, project, results})
        Process.sleep(:infinity)
      end)

    assert_receive {:acquired, ^project, results}, 1_000
    {pid, results}
  end

  describe "machine ceiling" do
    test "two projects with 10 ready each never hold more than 12, nor more than 8 apiece" do
      start_supervised!({Capacity, ceiling: 12, projects: %{"o/a" => 8, "o/b" => 8}})

      {_a, a} = orchestrator("o/a", Enum.to_list(1..10))
      {_b, b} = orchestrator("o/b", Enum.to_list(11..20))

      assert Enum.count(a, &(&1 == :ok)) == 8
      assert Enum.count(b, &(&1 == :ok)) == 4
      assert %{held: 12} = Capacity.snapshot()
      assert Capacity.acquire("o/b", 99) == {:error, :machine_full}
      assert Enum.member?(a, {:error, :project_full})
      assert Capacity.headroom("o/a") == 0
    end

    test "a project max below the machine ceiling binds although the machine has room" do
      start_supervised!({Capacity, ceiling: 12, projects: %{"o/a" => 3, "o/b" => 8}})
      orchestrator("o/a", Enum.to_list(1..10))

      assert Capacity.headroom("o/a") == 0
      assert Capacity.headroom("o/b") == 8
    end

    test "acquire is idempotent per issue" do
      start_supervised!({Capacity, ceiling: 2, projects: %{"o/a" => nil}})

      assert Capacity.acquire("o/a", 1) == :ok
      assert Capacity.acquire("o/a", 1) == :ok
      assert Capacity.headroom("o/a") == 1
    end
  end

  describe "release" do
    test "a crashed orchestrator returns its grants within a second" do
      start_supervised!({Capacity, ceiling: 12, projects: %{"o/a" => 8, "o/b" => 8}})
      {a, _} = orchestrator("o/a", Enum.to_list(1..5))
      assert Capacity.headroom("o/b") == 7

      Process.exit(a, :kill)

      assert eventually(fn -> Capacity.headroom("o/b") == 8 end)
      assert %{held: 0} = Capacity.snapshot()
    end

    test "sync replaces the holders so finished work frees slots" do
      start_supervised!({Capacity, ceiling: 12, projects: %{"o/a" => nil}})
      {a, _} = orchestrator("o/a", [:a, :b, :c])
      assert Capacity.headroom("o/a") == 9

      assert :ok = Capacity.sync("o/a", [:a])
      assert Capacity.headroom("o/a") == 11
      assert Process.alive?(a)
    end
  end

  describe "without a broker or for an unknown project" do
    test "headroom is unbounded and acquire grants" do
      assert Capacity.headroom("o/a") == :infinity
      assert Capacity.acquire("o/a", 1) == :ok
      assert Capacity.snapshot() == :unavailable
    end

    test "an unconfigured project is not bounded" do
      start_supervised!({Capacity, ceiling: 1, projects: %{"o/a" => 1}})

      assert Capacity.headroom("unknown/repo") == :infinity
      assert Capacity.acquire("unknown/repo", 1) == :ok
    end
  end

  describe "a slow broker" do
    test "refuses acquire instead of granting past the ceiling" do
      pid = start_supervised!({Capacity, ceiling: 1, projects: %{"o/a" => nil}})
      :sys.suspend(pid)
      on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)

      assert Capacity.acquire("o/a", 1) == {:error, :broker_timeout}
    end
  end

  defp eventually(fun, tries \\ 20) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
