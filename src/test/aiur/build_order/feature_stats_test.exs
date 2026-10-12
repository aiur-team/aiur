defmodule Aiur.BuildOrder.FeatureStatsTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.FeatureStats, as: Stats
  alias Aiur.BuildOrder.History.Row
  @now 1_791_408_000_000
  @day 86_400_000

  defp registry(numbers, baseline \\ :none) do
    %{features: %{"f" => %{baseline: baseline}}, also: %{}, owners: Map.new(numbers, &{&1, %{feature: "f", joined_at: DateTime.from_unix!(@now, :millisecond)}})}
  end

  defp fact(status, cx \\ 2, progress \\ {:known, 50}), do: Stats.fact(%Row{labels: ["complexity:#{cx}"]}, status, progress)

  defp stats(facts, registry \\ nil) do
    Stats.compute_all(registry || registry(Map.keys(facts)), facts, now: @now)["f"]
  end

  test "done counts only done, total counts every owner; closed has no weight" do
    facts = [:done, :failed, :not_planned, :closed, :running, :queued, :open] |> Enum.with_index(1) |> Map.new(fn {s, n} -> {n, fact(s)} end)
    assert %{total: 7, done: 1, done_min: 1, pct: 50, reasons: []} = stats(facts)
    assert %{pct: 0, reasons: []} = stats(%{1 => fact(:closed), 2 => fact(:queued)})
  end

  test "weighted matches the design formula" do
    assert stats(%{1 => fact(:done, 1), 2 => fact(:running, 3), 3 => fact(:queued, 5)}).pct == 21
  end

  test "failed counts as finished weight, not planned is out" do
    assert stats(%{1 => fact(:failed), 2 => fact(:not_planned), 3 => fact(:queued)}).pct == 50
  end

  test "half rounds up" do
    assert stats(%{1 => fact(:running, 1, {:known, 25}), 2 => fact(:queued, 1)}).pct == 13
  end

  test "unknown and invalid progress retain only a lower bound" do
    for progress <- [{:unknown, :stale}, {:known, 140}, {:known, -1}, {:known, 50.0}, nil] do
      assert %{pct: nil, pct_min: 50, reasons: [:progress]} = stats(%{1 => fact(:running, 3, progress), 2 => fact(:done, 3)})
    end
  end

  test "missing history keeps registry figures and does not claim no weight" do
    result = stats(%{}, registry([1, 2, 3]))
    assert %{total: 3, done: nil, done_min: 0, pct: nil, pct_min: nil, orig: 3, added: 0, spark: [3], reasons: [:complexity, :status]} = result
    assert Stats.fact(:missing, :unknown, {:unknown, :missing}).complexity == :unknown
    assert Stats.fact(%Row{}, :queued, {:known, 0}).complexity == :unknown
  end

  test "unknown status with known complexity keeps a lower bound" do
    assert %{done: nil, done_min: 1, pct: nil, pct_min: 50, reasons: [:status]} = stats(%{1 => fact(:unknown), 2 => fact(:done)})
  end

  test "baseline splits original and added, including returning originals" do
    facts = Map.new(1..3, &{&1, fact(:queued)})
    baseline = %{at: DateTime.from_unix!(@now, :millisecond), members: MapSet.new([1, 2])}
    assert %{orig: 2, added: 1, baseline?: true} = stats(facts, registry([1, 2, 3], baseline))
    assert %{orig: 3, added: 0, baseline?: false} = stats(facts)
  end

  test "also-only and non-work-only features have no weighted percentage" do
    r = %{registry([]) | also: %{7 => ["f"], 8 => ["f", "f"]}}
    assert %{total: 0, done: 0, pct: nil, pct_min: nil, reasons: [:no_weight], spark: [0], also: 2} = stats(%{}, r)
    assert %{pct: nil, reasons: [:no_weight]} = stats(%{1 => fact(:closed, :unknown), 2 => fact(:not_planned, :unknown)})
  end

  test "owner links are not counted as also" do
    r = %{registry([1, 2]) | also: %{2 => ["f"], 3 => ["f"], 4 => ["g"]}}
    assert %{total: 2, also: 1} = stats(%{}, r)
  end

  test "spark follows the design loop and appends future joins" do
    for {times, expected} <- [
          {[@now - 2 * @day, @now - @day, @now - 3_600_000], [1, 2, 3]},
          {[@now - 2 * @day, @now - @day, @now - 3_600_000, @now + 5 * @day], [1, 2, 3, 4]},
          {[@now + 5 * @day], [1]},
          {[@now + 1], [1]},
          {[@now - @day, @now + 1], [1, 1, 2]}
        ] do
      owners = times |> Enum.with_index(1) |> Map.new(fn {t, n} -> {n, %{feature: "f", joined_at: DateTime.from_unix!(t, :millisecond)}} end)
      assert stats(%{}, %{registry([]) | owners: owners}).spark == expected
    end
  end

  test "every registry feature gets figures independently of a loaded window" do
    r = %{features: Map.new(1..9, &{"f#{&1}", %{baseline: :none}}), also: %{}, owners: Map.new(1..2000, &{&1, %{feature: "f#{rem(&1, 8) + 1}", joined_at: DateTime.from_unix!(@now, :millisecond)}})}
    all = Stats.compute_all(r, Map.new(1..2000, &{&1, fact(:done)}), now: @now)
    assert map_size(all) == 9
    assert all["f9"].total == 0
    assert all["f1"].done == 250
  end

  test "label is not an input (future regression guard)" do
    r = registry([1])
    assert Stats.compute_all(put_in(r, [:features, "f", :label], "A"), %{}, now: @now) == Stats.compute_all(put_in(r, [:features, "f", :label], "B"), %{}, now: @now)
  end

  test "points table" do
    assert Enum.map(1..5, &Stats.points/1) == [1, 2, 3, 5, 8]
    assert Stats.points(:unknown) == :unknown
  end

  test "JSON keeps nil, names baseline and sorts unique reasons" do
    result = %{stats(%{}, registry([1])) | reasons: [:progress, :complexity, :progress]}

    assert Stats.to_json(result) == %{
             "total" => 1,
             "done" => nil,
             "done_min" => 0,
             "pct" => nil,
             "pct_min" => nil,
             "orig" => 1,
             "added" => 0,
             "baseline" => false,
             "spark" => [1],
             "also" => 0,
             "reasons" => ["complexity", "progress"]
           }
  end

  test "unknown complexity gives no lower bound" do
    unknown = Stats.fact(%Row{labels: ["bug"]}, :queued, {:known, 0})
    assert %{pct: nil, pct_min: nil, reasons: [:complexity]} = stats(%{1 => fact(:done, 1), 2 => unknown})
  end
end
