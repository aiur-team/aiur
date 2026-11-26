defmodule Aiur.Intent.ReconcilerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Aiur.IntentFixtures

  alias Aiur.Intent.Reconciler

  @item {"ticket", "aiur-team/aiur#7626", "order_key"}
  @pause {"fleet", "fleet", "pause"}

  defp h(id, wall, v, o \\ %{}), do: change(Map.merge(%{change_id: id, slot: "human", value_json: v, hlc_wall_ms: wall}, o))
  defp e(id, wall, v, o \\ %{}), do: h(id, wall, v, Map.merge(%{slot: "executor", author_id: "executor:x"}, o))
  defp d(id, wall, v, o \\ %{}), do: h(id, wall, v, Map.merge(%{slot: "default", author_id: "daemon"}, o))
  defp forced(id, wall, v, sup, reason \\ "stuck"), do: e(id, wall, v, %{force: true, supersedes: sup, reason: reason})

  defp pause(slot, id, wall, v, o \\ %{}),
    do: h(id, wall, v, Map.merge(%{slot: slot, entity_kind: "fleet", entity_key: "fleet", field: "pause"}, o))

  # Every assertion holds for the list, its reverse, and every change delivered twice.
  defp eff(changes, reg \\ @item, opts \\ []) do
    results = for set <- [changes, Enum.reverse(changes), changes ++ changes], do: Reconciler.fold(set, opts)
    assert [first | rest] = results
    assert Enum.all?(rest, &(&1 == first))
    first[reg] && first[reg].effective
  end

  test "row 1: executor sits beneath a human value" do
    assert eff([h("h", 10, "a"), e("e", 20, "b")]) == "a"
    assert Reconciler.fold([h("h", 10, "a"), e("e", 20, "b")])[@item].slots.executor.change_id == "e"
  end

  test "row 2: human, forced executor, human again ends with the second human" do
    assert eff([h("h1", 10, "a"), forced("e", 20, "b", "h1"), h("h2", 30, "c")]) == "c"
  end

  test "row 3: a forced executor naming a stale human change clears nothing" do
    assert eff([h("h1", 10, "a"), h("h2", 20, "c"), forced("e", 30, "b", "h1")]) == "c"
  end

  test "row 4: a forced takeover of the current human change wins and is marked" do
    set = [h("h1", 10, "a"), forced("e", 20, "b", "h1")]
    assert eff(set) == "b"
    assert Reconciler.fold(set)[@item].takeover == "e"
  end

  test "row 5: a force without a reason is not honoured" do
    assert eff([h("h1", 10, "a"), forced("e", 20, "b", "h1", "")]) == "a"
    assert eff([h("h1", 10, "a"), forced("e", 20, "b", "h1", "  ")]) == "a"
  end

  test "row 6: a late offline human edit cancels the takeover retroactively" do
    assert eff([h("h1", 10, "a"), forced("e", 20, "b", "h1"), h("h3", 15, "d")]) == "d"
  end

  test "row 7: an Executor with a slow clock cannot take over" do
    assert eff([forced("e", 5, "b", "h1"), h("h1", 10, "a")]) == "a"
  end

  test "rows 12 and 13: a daemon never displaces a human value or pause" do
    assert eff([h("h", 10, "a"), d("d", 99, "z")]) == "a"
    assert eff([pause("human", "u", 10, false), pause("default", "dp", 20, true)], @pause) == false
  end

  test "row 9 and 10: pause is any-slot, a later human unpause clears" do
    assert eff([pause("human", "u", 10, false), pause("executor", "p", 20, true)], @pause) == true
    assert eff([pause("executor", "p", 10, true), pause("human", "u", 20, false)], @pause) == false
  end

  test "row 11: pause wins an exact HLC tie whatever the origin names" do
    set = [pause("human", "u", 10, false, %{origin_gateway: "Z"}), pause("executor", "p", 10, true, %{origin_gateway: "A"})]
    assert eff(set, @pause) == true
  end

  test "row 14: equal HLC humans are broken by origin" do
    set = [h("x", 10, "a", %{origin_gateway: "A"}), h("y", 10, "b", %{origin_gateway: "B"})]
    assert eff(set) == "b"
    assert Reconciler.fold(set)[@item].winning_change_id == "y"
  end

  test "registers of different entities are independent" do
    set = [h("a", 10, "1"), h("b", 10, "2", %{entity_key: "aiur-team/aiur#2"})]
    folded = Reconciler.fold(set)
    assert folded[@item].effective == "1"
    assert folded[{"ticket", "aiur-team/aiur#2", "order_key"}].effective == "2"
  end

  describe "far-future hold" do
    @n 1_000_000

    test "row 15: held while more than 60 s ahead, applied once the clock catches up" do
      set = [h("old", @n - 10, "a", %{origin_gateway: "R"}), h("new", @n + 90_000, "f", %{origin_gateway: "R"})]
      assert eff(set, @item, now_ms: @n, own_gateway: "L") == "a"
      assert eff(set, @item, now_ms: @n + 50_000, own_gateway: "L") == "f"
    end

    test "exactly 60 s applies, 61 s is held" do
      assert eff([h("a", @n + 60_000, "x", %{origin_gateway: "R"})], @item, now_ms: @n, own_gateway: "L") == "x"
      assert eff([h("a", @n + 61_000, "x", %{origin_gateway: "R"})], @item, now_ms: @n, own_gateway: "L") == nil
    end

    test "own changes are never held (clock set back)" do
      assert eff([h("a", @n + 300_000, "x", %{origin_gateway: "L"})], @item, now_ms: @n, own_gateway: "L") == "x"
    end

    test "held/3 shares the predicate" do
      far = h("a", @n + 61_000, "x", %{origin_gateway: "R"})
      assert [^far] = Reconciler.held([far, far, h("b", @n, "y")], @n, "L")
    end
  end

  property "any permutation, with duplicates, folds to the same registers" do
    check all(
            specs <- StreamData.list_of(spec(), min_length: 2, max_length: 6),
            seed <- StreamData.integer()
          ) do
      set = specs |> Enum.with_index() |> Enum.map(fn {s, i} -> build(s, i) end)
      expected = Reconciler.fold(set)
      :rand.seed(:exsss, {seed, 1, 2})
      assert Reconciler.fold(Enum.shuffle(set ++ Enum.take_random(set, 2))) == expected
    end
  end

  property "a default change never changes the effective value of a register that has a human or executor value" do
    check all(specs <- StreamData.list_of(spec(), min_length: 1, max_length: 5), wall <- StreamData.integer(1..6)) do
      set = specs |> Enum.with_index() |> Enum.map(fn {s, i} -> build(s, i) end)
      before = Reconciler.fold(set)
      extra = d("daemon", wall, "z")
      after_ = Reconciler.fold([extra | set])

      for {reg, %{slot: slot, effective: v}} <- before, slot in [:human, :executor], elem(reg, 2) == "order_key" do
        assert after_[reg].effective == v
      end
    end
  end

  defp spec do
    StreamData.tuple({
      StreamData.member_of(["human", "executor"]),
      StreamData.integer(1..4),
      StreamData.integer(0..1),
      StreamData.member_of(["A", "B", "C"]),
      StreamData.boolean(),
      StreamData.integer(0..5)
    })
  end

  # `supersedes` indexes into earlier ids, sometimes past the end (a ghost id).
  defp build({slot, wall, counter, origin, force?, sup}, i) do
    base = %{change_id: "c#{i}", slot: slot, hlc_wall_ms: wall, hlc_counter: counter, origin_gateway: origin, value_json: "v#{i}"}

    if slot == "executor" and force?,
      do: change(Map.merge(base, %{force: true, reason: "r", supersedes: "c#{sup}", author_id: "executor:x"})),
      else: change(base)
  end
end
