defmodule Aiur.Gateway.AllocationTest do
  use ExUnit.Case, async: true

  alias Aiur.Gateway.Allocation

  # The 19 cases from the MPG-401 policy table, verbatim.
  @cases [
    %{
      name: "scope worked example: fill in priority order up to each hard max",
      capacity: 12,
      demands: %{{"A", :none} => %{ready: 10, promoted: 0}, {"B", :none} => %{ready: 10, promoted: 0}, {"C", :none} => %{ready: 10, promoted: 0}},
      priorities: [{"A", :none}, {"B", :none}, {"C", :none}],
      limits: %{"A" => 3, "B" => 5, "C" => 8},
      running: %{},
      grants: %{{"A", :none} => 3, {"B", :none} => 5, {"C", :none} => 4}
    },
    %{
      name: "high-priority project has no eligible work: lower ones borrow",
      capacity: 12,
      demands: %{{"A", :none} => %{ready: 0, promoted: 0}, {"B", :none} => %{ready: 10, promoted: 0}, {"C", :none} => %{ready: 10, promoted: 0}},
      priorities: [{"A", :none}, {"B", :none}, {"C", :none}],
      limits: %{"A" => 3, "B" => 5, "C" => 8},
      running: %{},
      grants: %{{"B", :none} => 5, {"C", :none} => 7}
    },
    %{
      name: "swapping priority changes who gets slots, never how many",
      capacity: 12,
      demands: %{{"A", :none} => %{ready: 10, promoted: 0}, {"B", :none} => %{ready: 10, promoted: 0}, {"C", :none} => %{ready: 10, promoted: 0}},
      priorities: [{"C", :none}, {"B", :none}, {"A", :none}],
      limits: %{"A" => 3, "B" => 5, "C" => 8},
      running: %{},
      grants: %{{"C", :none} => 8, {"B", :none} => 4}
    },
    %{
      name: "focus: the first feature fills before the second, unfeatured work last",
      capacity: 6,
      demands: %{{"A", "f1"} => %{ready: 4, promoted: 0}, {"A", "f2"} => %{ready: 5, promoted: 0}, {"A", :none} => %{ready: 3, promoted: 0}},
      priorities: [{"A", "f1"}, {"A", "f2"}, {"A", :none}],
      limits: %{},
      running: %{},
      grants: %{{"A", "f1"} => 4, {"A", "f2"} => 2}
    },
    %{
      name: "focus never idles: what the focus feature cannot use goes to the next project",
      capacity: 6,
      demands: %{{"A", "f1"} => %{ready: 2, promoted: 0}, {"B", "g1"} => %{ready: 10, promoted: 0}},
      priorities: [{"A", "f1"}, {"B", "g1"}],
      limits: %{},
      running: %{},
      grants: %{{"A", "f1"} => 2, {"B", "g1"} => 4}
    },
    %{
      name: "running agents use capacity and project headroom",
      capacity: 12,
      demands: %{{"A", :none} => %{ready: 10, promoted: 0}, {"B", :none} => %{ready: 10, promoted: 0}, {"C", :none} => %{ready: 10, promoted: 0}},
      priorities: [{"A", :none}, {"B", :none}, {"C", :none}],
      limits: %{"A" => 3, "B" => 5, "C" => 8},
      running: %{{"A", :none} => 3, {"B", :none} => 2},
      grants: %{{"B", :none} => 3, {"C", :none} => 4}
    },
    %{
      name: "a project over a lowered limit gets nothing and loses nothing",
      capacity: 8,
      demands: %{{"A", :none} => %{ready: 5, promoted: 0}, {"B", :none} => %{ready: 5, promoted: 0}},
      priorities: [{"A", :none}, {"B", :none}],
      limits: %{"A" => 2},
      running: %{{"A", :none} => 4},
      grants: %{{"B", :none} => 4}
    },
    %{
      name: "capacity lowered below running: no grants, no stops",
      capacity: 4,
      demands: %{{"A", :none} => %{ready: 5, promoted: 0}, {"B", :none} => %{ready: 5, promoted: 0}},
      priorities: [{"A", :none}, {"B", :none}],
      limits: %{},
      running: %{{"A", :none} => 3, {"B", :none} => 3},
      grants: %{}
    },
    %{
      name: "a promoted ticket in a low-priority project wins the next free slot",
      capacity: 4,
      demands: %{{"A", :none} => %{ready: 5, promoted: 0}, {"C", :none} => %{ready: 3, promoted: 1}},
      priorities: [{"A", :none}, {"C", :none}],
      limits: %{},
      running: %{{"A", :none} => 3},
      grants: %{{"C", :none} => 1}
    },
    %{
      name: "a promoted ticket never preempts",
      capacity: 4,
      demands: %{{"A", :none} => %{ready: 5, promoted: 0}, {"C", :none} => %{ready: 3, promoted: 1}},
      priorities: [{"A", :none}, {"C", :none}],
      limits: %{},
      running: %{{"A", :none} => 4},
      grants: %{}
    },
    %{
      name: "a promoted ticket respects its project limit; the slot goes to other work",
      capacity: 4,
      demands: %{{"A", :none} => %{ready: 5, promoted: 0}, {"C", :none} => %{ready: 3, promoted: 1}},
      priorities: [{"A", :none}, {"C", :none}],
      limits: %{"C" => 2},
      running: %{{"C", :none} => 2},
      grants: %{{"A", :none} => 2}
    },
    %{
      name: "a feature limit passes the rest to the next feature",
      capacity: 4,
      demands: %{{"A", "f1"} => %{ready: 5, promoted: 0}, {"A", "f2"} => %{ready: 5, promoted: 0}},
      priorities: [{"A", "f1"}, {"A", "f2"}],
      limits: %{{"A", "f1"} => 1},
      running: %{},
      grants: %{{"A", "f1"} => 1, {"A", "f2"} => 3}
    },
    %{
      name: "a project limit is shared by all its features",
      capacity: 8,
      demands: %{{"A", "f1"} => %{ready: 2, promoted: 0}, {"A", "f2"} => %{ready: 5, promoted: 0}, {"B", :none} => %{ready: 5, promoted: 0}},
      priorities: [{"A", "f1"}, {"A", "f2"}, {"B", :none}],
      limits: %{"A" => 3},
      running: %{},
      grants: %{{"A", "f1"} => 2, {"A", "f2"} => 1, {"B", :none} => 5}
    },
    %{
      name: "unlisted groups follow the listed ones in key order",
      capacity: 4,
      demands: %{{"A", :none} => %{ready: 1, promoted: 0}, {"C", :none} => %{ready: 5, promoted: 0}, {"B", :none} => %{ready: 2, promoted: 0}},
      priorities: [{"A", :none}],
      limits: %{},
      running: %{},
      grants: %{{"A", :none} => 1, {"B", :none} => 2, {"C", :none} => 1}
    },
    %{
      name: "slots stay idle only when every group with ready work is at a limit",
      capacity: 6,
      demands: %{{"A", :none} => %{ready: 5, promoted: 0}, {"B", :none} => %{ready: 5, promoted: 0}},
      priorities: [{"A", :none}, {"B", :none}],
      limits: %{"A" => 1, "B" => 1},
      running: %{},
      grants: %{{"A", :none} => 1, {"B", :none} => 1}
    },
    %{name: "no eligible work: no grants", capacity: 6, demands: %{{"A", :none} => %{ready: 0, promoted: 0}}, priorities: [{"A", :none}], limits: %{}, running: %{{"B", :none} => 1}, grants: %{}},
    %{
      name: "reclaim by waiting, step 1: A has no ready work, B borrows every slot",
      capacity: 2,
      demands: %{{"A", :none} => %{ready: 0, promoted: 0}, {"B", :none} => %{ready: 3, promoted: 0}},
      priorities: [{"A", :none}, {"B", :none}],
      limits: %{},
      running: %{},
      grants: %{{"B", :none} => 2}
    },
    %{
      name: "reclaim by waiting, step 2: A becomes ready while B holds every slot",
      capacity: 2,
      demands: %{{"A", :none} => %{ready: 3, promoted: 0}, {"B", :none} => %{ready: 3, promoted: 0}},
      priorities: [{"A", :none}, {"B", :none}],
      limits: %{},
      running: %{{"B", :none} => 2},
      grants: %{}
    },
    %{
      name: "reclaim by waiting, step 3: the slot B frees goes to A",
      capacity: 2,
      demands: %{{"A", :none} => %{ready: 3, promoted: 0}, {"B", :none} => %{ready: 2, promoted: 0}},
      priorities: [{"A", :none}, {"B", :none}],
      limits: %{},
      running: %{{"B", :none} => 1},
      grants: %{{"A", :none} => 1}
    }
  ]

  for {c, i} <- Enum.with_index(@cases, 1) do
    @case_data c
    test "case #{i}: #{c.name}" do
      c = @case_data
      assert Allocation.allocate(c.capacity, c.demands, c.priorities, c.limits, c.running) == c.grants
    end
  end

  test "P1, P2, P3 and the free-slot bound hold on random inputs" do
    :rand.seed(:exsss, {401, 402, 403})
    groups = for p <- ~w(A B C), f <- [:none, "f1", "f2"], do: {p, f}
    sum = fn counts, p -> for({{^p, _}, n} <- counts, reduce: 0, do: (acc -> acc + n)) end
    total = fn grants -> grants |> Map.values() |> Enum.sum() end
    at_limit? = fn limits, key, used -> Map.has_key?(limits, key) and used >= limits[key] end

    for _ <- 1..2000 do
      demands =
        Map.new(
          groups,
          &{&1,
           (
             r = Enum.random(0..4)
             %{ready: r, promoted: Enum.random(0..r)}
           )}
        )

      running = Map.new(Enum.take_random(groups, 3), &{&1, Enum.random(0..3)})
      limits = Map.new(Enum.take_random(~w(A B C) ++ groups, 3), &{&1, Enum.random(0..4)})
      capacity = Enum.random(0..14)
      free = max(capacity - total.(running), 0)
      g1 = Allocation.allocate(capacity, demands, groups, limits, running)
      g2 = Allocation.allocate(capacity, demands, Enum.shuffle(groups), limits, running)

      # P1 and the bound: priority changes who gets slots, never how many.
      assert total.(g1) == total.(g2)
      assert total.(g1) <= free

      for g <- [g1, g2] do
        # P2: no group or project ends above max(limit, running).
        for {key, limit} <- limits do
          {r, n} =
            if is_tuple(key),
              do: {Map.get(running, key, 0), Map.get(g, key, 0)},
              else: {sum.(running, key), sum.(g, key)}

          assert r + n <= max(limit, r)
        end

        # P3: a slot stays free only when every group with ungranted ready work is at a limit.
        if total.(g) < free do
          for {{p, _} = grp, d} <- demands, d.ready > Map.get(g, grp, 0) do
            assert at_limit?.(limits, grp, Map.get(running, grp, 0) + Map.get(g, grp, 0)) or
                     at_limit?.(limits, p, sum.(running, p) + sum.(g, p))
          end
        end
      end
    end
  end
end
