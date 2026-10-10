defmodule Aiur.BuildOrder.History.EdgesTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.History.{Edges, Row}
  alias Aiur.BuildOrder.{Lifecycle, ProviderHealth}
  alias AiurWeb.Build.Payload
  @repo %{owner: "aiur-team", repository: "aiur"}
  @fixtures Path.expand("../../../fixtures/build_home", __DIR__)

  test "closed first or equal ends are cleared; later or open blockers violate order" do
    for end_time <- [date(1), date(2)] do
      result = build([row(10, :completed, end_time), row(12, :completed, date(2), [ref(10)])])
      assert [%{state: :cleared, order: :in_order, causes: [], missing: false}] = result.edges
      assert Edges.to_payload(result.by_ticket, 12) == %{deps: ["10"], children: [], dep_states: %{"10" => "cleared"}, deps_missing: 0}
      assert Edges.to_payload(result.by_ticket, 10).children == ["12"]
    end

    for blocker <- [row(10, :completed, date(3)), row(10, :open)] do
      assert [%{state: :terminal_unsatisfied, order: :violated, causes: [:closed_before_blocker]}] = build([blocker, row(12, :completed, date(1), [ref(10)])]).edges
    end
  end

  test "unknown and none ends keep cleared state and unknown order" do
    for end_time <- [:unknown, :none], side <- [:blocked, :blocker] do
      blocker = row(10, :completed, if(side == :blocker, do: end_time, else: date(1)))
      blocked = row(12, :completed, if(side == :blocked, do: end_time, else: date(2)), [ref(10)])
      assert [%{state: :cleared, order: :unknown, causes: []}] = build([blocker, blocked]).edges
    end
  end

  test "external and absent blockers are counted; mixed-case native pairs deduplicate" do
    refs = [ref(10), %{ref(10) | owner: "Aiur-Team", repository: "AIUR"}, ref(999), %{ref(4) | owner: "private-owner", repository: "secret"}]
    result = build([row(10, :open), row(12, :open, :none, refs)])
    assert length(result.edges) == 3
    assert Enum.count(result.edges, &(&1.missing == true and &1.state == :unknown and &1.causes == [:not_in_index])) == 2
    payload = Edges.to_payload(result.by_ticket, 12)
    assert payload == %{deps: ["10"], children: [], dep_states: %{"10" => "blocking"}, deps_missing: 2}
    refute Jason.encode!(payload) =~ "private-owner"
    refute Map.has_key?(result.by_ticket, 999)
  end

  test "incomplete stores keep every state and missing count unknown" do
    result = build([row(10, :completed, date(3)), row(12, :completed, date(1), [ref(10), ref(999)])], false)
    assert Enum.all?(result.edges, &(&1.state == :unknown))
    assert Enum.find(result.edges, &(&1.blocker.number == 999)).missing == nil
    assert Edges.to_payload(result.by_ticket, 12).deps_missing == nil
    assert Edges.to_payload(result.by_ticket, 123).deps_missing == nil
    assert Edges.to_payload(build([]).by_ticket, 123).deps_missing == 0
  end

  test "unhealthy stores fail closed" do
    for state <- [:unavailable, :stale, :structurally_invalid] do
      assert Edges.build(%{rows: %{}, health: ProviderHealth.new(1, state, true)}, @repo) == {:error, :unavailable}
    end
  end

  test "unknown or cut lists report unknown missing counts" do
    unknown = %{row(1, :open) | blocked_by: :unknown}
    cut = %{row(2, :open, :none, [ref(1), ref(999)]) | blocked_by_complete: false}
    result = build([unknown, cut])
    assert Edges.to_payload(result.by_ticket, 1) == %{deps: [], children: ["2"], dep_states: %{}, deps_missing: nil}
    assert Edges.to_payload(result.by_ticket, 2) == %{deps: ["1"], children: [], dep_states: %{"1" => "blocking"}, deps_missing: nil}
    assert length(result.edges) == 2
  end

  test "not-planned cause survives with and without a violation" do
    for {end_time, order, causes} <- [{date(1), :in_order, [:blocker_not_planned]}, {date(3), :violated, [:blocker_not_planned, :closed_before_blocker]}] do
      assert [%{state: :terminal_unsatisfied, order: ^order, causes: ^causes}] = build([row(10, :not_planned, end_time), row(12, :completed, date(2), [ref(10)])]).edges
    end
  end

  test "duplicate and unknown blocker lifecycles never become satisfied or violation states" do
    for {reason, order, causes} <- [{:duplicate, :violated, [:closed_before_blocker]}, {:unknown, :unknown, []}] do
      assert [%{state: :unknown, order: ^order, causes: ^causes}] = build([row(10, reason, date(3)), row(12, :completed, date(1), [ref(10)])]).edges
    end
  end

  test "reopened and non-completed blocked tickets make no order claim" do
    for reason <- [:reopened, :not_planned, :duplicate, :unknown] do
      assert [%{state: :blocking, order: :not_closed, causes: []}] = build([row(10, :open), row(12, reason, date(1), [ref(10)])]).edges
    end
  end

  test "cycles terminate; self loops stay out of projections (future walk regression guard)" do
    result = build([row(1, :open, :none, [ref(2)]), row(2, :open, :none, [ref(1)]), row(7, :open, :none, [ref(7)])])
    assert Edges.to_payload(result.by_ticket, 1).children == ["2"]
    assert Edges.to_payload(result.by_ticket, 2).children == ["1"]
    assert Edges.to_payload(result.by_ticket, 7) == %{deps: [], children: [], dep_states: %{}, deps_missing: 0}
    assert Enum.find(result.edges, &(&1.blocked == 7)).causes == [:self_loop]
    assert Enum.all?(result.edges, &(&1.state == :blocking))
  end

  test "numeric ids sort and input row order is irrelevant" do
    rows = [row(2, :open), row(10, :open), row(12, :open, :none, [ref(10), ref(2)]), row(3, :open, :none, [ref(2)])]
    result = build(rows)
    assert result == build(Enum.reverse(rows))
    assert Edges.to_payload(result.by_ticket, 12).deps == ["2", "10"]
    assert Edges.to_payload(result.by_ticket, 2).children == ["3", "12"]
  end

  test "design datasets preserve children and lifecycle classes" do
    for dataset <- ~w(live dense newrepo noqueue) do
      fixture = json(dataset)
      tickets = fixture["sections"] |> Map.values() |> List.flatten()

      rows =
        Enum.map(tickets, fn t ->
          reason =
            case t["status"] do
              "done" -> :completed
              "failed" -> :not_planned
              _status -> :open
            end

          row(t["num"], reason, if(t["end"], do: DateTime.from_unix!(t["end"], :millisecond), else: :none), Enum.map(t["deps"], &ref(String.to_integer(&1))))
        end)

      result = build(rows)
      by_id = Map.new(tickets, &{&1["id"], &1})

      for t <- tickets do
        projection = Edges.to_payload(result.by_ticket, t["num"])
        assert projection.children == t["children"]
        assert Enum.sort(projection.deps) == Enum.sort(t["deps"])
        assert projection.deps_missing == 0

        for {id, state} <- projection.dep_states do
          expected =
            case by_id[id]["status"] do
              "done" -> "cleared"
              "failed" -> "terminal_unsatisfied"
              _status -> "blocking"
            end

          assert state == expected
        end
      end
    end
  end

  test "odd edges fixture matches history inputs and wire contract" do
    fixture = json("odd-edges-history")

    rows =
      Enum.map(fixture["rows"], fn r ->
        refs = Enum.map(r["blocked_by"], &%{owner: &1["owner"], repository: &1["repository"], number: &1["number"]})

        row(
          r["number"],
          String.to_existing_atom(r["lifecycle"]["state_reason"]),
          if(is_integer(r["end"]), do: DateTime.from_unix!(r["end"], :millisecond), else: String.to_existing_atom(r["end"])),
          refs
        )
      end)

    result = build(rows)
    snapshot = json("odd-edges")
    assert :ok == Payload.validate(snapshot)

    for t <- snapshot["sections"] |> Map.values() |> List.flatten() do
      assert Payload.scrub(Edges.to_payload(result.by_ticket, t["num"])) == fixture["expected"][t["id"]]
    end

    {:ok, registered} = Aiur.TestSupport.BuildHome.FixtureSource.full(dataset: "odd-edges")
    assert registered == snapshot
  end

  test "wire validation rejects mismatched states and invalid edge fields" do
    snapshot = json("live")
    assert :ok == Payload.validate(snapshot)

    for {field, value} <- [{"dep_states", %{"999" => "cleared"}}, {"dep_states", %{"999" => "ok"}}, {"children", [999]}, {"deps_missing", -1}] do
      invalid = put_in(snapshot, ["sections", "nq", Access.at(0), field], value)
      assert {:error, errors} = Payload.validate(invalid)
      assert Enum.any?(errors, fn {path, _reason} -> String.contains?(path, field) end)
    end

    assert :ok == Payload.validate(put_in(snapshot, ["sections", "nq", Access.at(0), "deps_missing"], nil))
  end

  defp build(rows, complete? \\ true) do
    {:ok, result} = Edges.build(%{rows: Map.new(rows, &{&1.number, &1}), health: ProviderHealth.new(1, :healthy, complete?)}, @repo)
    result
  end

  defp row(number, reason, end_time \\ :none, refs \\ []) do
    state =
      cond do
        reason in [:open, :none, :reopened] -> :open
        reason == :unknown -> :unknown
        true -> :closed
      end

    %Row{number: number, lifecycle: %Lifecycle{state: state, state_reason: if(reason == :open, do: :none, else: reason)}, end: end_time, blocked_by: refs, blocked_by_complete: true}
  end

  defp ref(number), do: Map.put(@repo, :number, number)
  defp date(day), do: DateTime.new!(Date.new!(2026, 9, day), ~T[10:00:00])
  defp json(name), do: @fixtures |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()
end
