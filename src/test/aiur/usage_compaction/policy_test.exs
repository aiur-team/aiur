defmodule Aiur.UsageCompaction.PolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.UsageCompaction.Policy

  defp facts(latest, retired, raw_bytes), do: %{latest_position: latest, retired_through: retired, raw_bytes: raw_bytes}

  test "retires the oldest positions beyond the max retained count, keeping the min window" do
    policy = Policy.new(min_retained_positions: 100, max_retained_positions: 300, retire_batch: 10_000, max_retained_bytes: :infinity)

    assert Policy.eligible_range(policy, facts(1_000, 0, 0)) == {:retire, 1, 700}
  end

  test "never retires into the minimum retained recovery window" do
    policy = Policy.new(min_retained_positions: 200, max_retained_positions: 1, retire_batch: 10_000, max_retained_bytes: :infinity)

    assert {:retire, 1, last} = Policy.eligible_range(policy, facts(1_000, 0, 0))
    assert last == 800
    assert 1_000 - last == 200
  end

  test "bounds a single cycle to the retire batch" do
    policy = Policy.new(min_retained_positions: 0, max_retained_positions: 1, retire_batch: 50, max_retained_bytes: :infinity)

    assert Policy.eligible_range(policy, facts(1_000, 100, 0)) == {:retire, 101, 150}
  end

  test "triggers on raw byte pressure even under the position ceiling" do
    policy = Policy.new(min_retained_positions: 10, max_retained_positions: :infinity, retire_batch: 10_000, max_retained_bytes: 1_000)

    # Under the byte cap: no position-count trigger, so noop.
    assert Policy.eligible_range(policy, facts(100, 0, 500)) == :noop
    # Over the byte cap: retire down to the min window.
    assert Policy.eligible_range(policy, facts(100, 0, 5_000)) == {:retire, 1, 90}
  end

  test "is a noop when nothing is eligible and never regresses the watermark" do
    policy = Policy.new(min_retained_positions: 100, max_retained_positions: 300, retire_batch: 10_000, max_retained_bytes: :infinity)

    assert Policy.eligible_range(policy, facts(50, 0, 0)) == :noop
    assert Policy.eligible_range(policy, facts(200, 0, 0)) == :noop
    # Already retired past the eligible point: no backward movement.
    assert Policy.eligible_range(policy, facts(1_000, 700, 0)) == :noop
  end

  test "returns a gapless prefix strictly below the retained window for any thresholds" do
    for min <- [0, 5, 50], max <- [1, 10, 100, :infinity], batch <- [1, 25, 100_000], latest <- [0, 40, 500] do
      policy = Policy.new(min_retained_positions: min, max_retained_positions: max, retire_batch: batch, max_retained_bytes: :infinity)

      case Policy.eligible_range(policy, facts(latest, 0, 0)) do
        :noop ->
          :ok

        {:retire, first, last} ->
          assert first == 1
          assert last >= first
          assert latest - last >= min
          assert last <= batch
      end
    end
  end

  test "clamps invalid config to safe defaults" do
    policy = Policy.new(min_retained_positions: -1, max_retained_positions: 0, retire_batch: 0)

    assert policy.min_retained_positions == 500
    assert policy.max_retained_positions == 5_000
    assert policy.retire_batch == 1_000
  end
end
