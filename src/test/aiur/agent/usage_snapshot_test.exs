defmodule Aiur.Agent.UsageSnapshotTest do
  @moduledoc """
  Tests for AgentUsageSnapshot calculation and unknown handling.

  Critical invariants verified:
  - Unknown values are never converted to zero
  - Cached proportion calculation handles all edge cases
  - Freshness assessment correctly classifies staleness
  - Formatting preserves unknowns without substitution
  """

  use ExUnit.Case

  alias Aiur.Agent.UsageSnapshot

  describe "calculate_cached_proportion/2" do
    test "calculates proportion when both dimensions are known and positive" do
      # 30 cached out of 100 total input = 30%
      result = UsageSnapshot.calculate_cached_proportion(100, 30)
      assert_in_delta(result, 0.3, 0.001)
    end

    test "returns 0.0 when cached_input is 0" do
      result = UsageSnapshot.calculate_cached_proportion(100, 0)
      assert result == 0.0
    end

    test "returns 1.0 when all input is cached" do
      result = UsageSnapshot.calculate_cached_proportion(100, 100)
      assert result == 1.0
    end

    test "returns error when input is unknown" do
      result = UsageSnapshot.calculate_cached_proportion({:unknown, :missing}, 30)
      assert result == {:unknown, :missing_input}
    end

    test "returns error when cached_input is unknown" do
      result = UsageSnapshot.calculate_cached_proportion(100, {:unknown, :missing})
      assert result == {:unknown, :missing_cached_input}
    end

    test "returns error when both input and cached_input are zero" do
      result = UsageSnapshot.calculate_cached_proportion(0, 0)
      assert result == {:unknown, :zero_input}
    end

    test "returns error when cached_input > input (impossible state)" do
      result = UsageSnapshot.calculate_cached_proportion(0, 50)
      assert result == {:unknown, :invalid_token_values}
    end

    test "does NOT convert unknown to zero" do
      # Critical mutation test: if code converts :unknown to 0, this should fail
      result = UsageSnapshot.calculate_cached_proportion({:unknown, :test}, 100)
      refute result == 0
      refute result == 0.0
      assert match?({:unknown, _}, result)
    end

    test "handles negative values gracefully" do
      # Should not crash, should return unknown or maintain invariant
      result = UsageSnapshot.calculate_cached_proportion(-100, 30)
      assert match?({:unknown, _}, result)
    end
  end

  describe "format_token_dimension/1" do
    test "formats known positive integer" do
      assert UsageSnapshot.format_token_dimension(100) == "100"
      assert UsageSnapshot.format_token_dimension(0) == "0"
      assert UsageSnapshot.format_token_dimension(999_999) == "999999"
    end

    test "formats unknown as dash symbol" do
      assert UsageSnapshot.format_token_dimension({:unknown, :missing}) == "—"
      assert UsageSnapshot.format_token_dimension({:unknown, :any_reason}) == "—"
    end

    test "never converts unknown to zero string" do
      # Critical: formatting should never produce "0" for an unknown
      result = UsageSnapshot.format_token_dimension({:unknown, :test})
      refute result == "0"
      assert result == "—"
    end

    test "handles invalid input safely" do
      assert UsageSnapshot.format_token_dimension(nil) == "—"
      assert UsageSnapshot.format_token_dimension("string") == "—"
      assert UsageSnapshot.format_token_dimension(-1) == "—"
    end
  end

  describe "format_cached_proportion/1" do
    test "formats known float as percentage" do
      assert UsageSnapshot.format_cached_proportion(0.5) == "50.0%"
      assert UsageSnapshot.format_cached_proportion(0.333) == "33.3%"
      assert UsageSnapshot.format_cached_proportion(0.0) == "0.0%"
      assert UsageSnapshot.format_cached_proportion(1.0) == "100.0%"
    end

    test "formats unknown as dash symbol" do
      assert UsageSnapshot.format_cached_proportion({:unknown, :missing}) == "—"
      assert UsageSnapshot.format_cached_proportion({:unknown, :zero_input}) == "—"
    end

    test "never converts unknown to zero percent" do
      result = UsageSnapshot.format_cached_proportion({:unknown, :test})
      refute result == "0%"
      refute result == "0.0%"
      assert result == "—"
    end

    test "handles invalid floats safely" do
      assert UsageSnapshot.format_cached_proportion(nil) == "—"
      assert UsageSnapshot.format_cached_proportion("50%") == "—"
      # > 1.0
      assert UsageSnapshot.format_cached_proportion(1.5) == "—"
      # < 0.0
      assert UsageSnapshot.format_cached_proportion(-0.1) == "—"
    end
  end

  describe "assess_freshness/1" do
    test "returns :current for observations < 5 minutes old" do
      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -60, :second)
      four_minutes_ago = DateTime.add(now, -240, :second)

      assert UsageSnapshot.assess_freshness(one_minute_ago) == :current
      assert UsageSnapshot.assess_freshness(four_minutes_ago) == :current
    end

    test "returns :stale for observations >= 5 minutes old" do
      now = DateTime.utc_now()
      five_minutes_ago = DateTime.add(now, -300, :second)
      one_hour_ago = DateTime.add(now, -3600, :second)

      assert UsageSnapshot.assess_freshness(five_minutes_ago) == :stale
      assert UsageSnapshot.assess_freshness(one_hour_ago) == :stale
    end

    test "returns :unknown when observed_at is nil" do
      assert UsageSnapshot.assess_freshness(nil) == :unknown
    end
  end

  describe "format_freshness/2" do
    test "formats current observations with age" do
      now = DateTime.utc_now()
      thirty_seconds_ago = DateTime.add(now, -30, :second)

      result = UsageSnapshot.format_freshness(:current, thirty_seconds_ago)
      assert String.contains?(result, "ago")
      refute String.contains?(result, "stale")
    end

    test "formats stale observations with age and label" do
      now = DateTime.utc_now()
      one_hour_ago = DateTime.add(now, -3600, :second)

      result = UsageSnapshot.format_freshness(:stale, one_hour_ago)
      assert String.contains?(result, "ago")
      assert String.contains?(result, "stale")
    end

    test "formats unknown freshness" do
      assert UsageSnapshot.format_freshness(:unknown, DateTime.utc_now()) == "unknown freshness"
      assert UsageSnapshot.format_freshness(:unknown, nil) == "unknown freshness"
    end

    test "handles nil observed_at gracefully" do
      assert UsageSnapshot.format_freshness(:current, nil) == "unknown freshness"
      assert UsageSnapshot.format_freshness(:stale, nil) == "unknown freshness"
    end

    test "formats age in seconds for recent observations" do
      now = DateTime.utc_now()
      thirty_seconds_ago = DateTime.add(now, -30, :second)

      result = UsageSnapshot.format_freshness(:current, thirty_seconds_ago)
      assert String.contains?(result, "s ago")
    end

    test "formats age in minutes for mid-range observations" do
      now = DateTime.utc_now()
      ten_minutes_ago = DateTime.add(now, -600, :second)

      result = UsageSnapshot.format_freshness(:stale, ten_minutes_ago)
      assert String.contains?(result, "m ago")
    end

    test "formats age in hours for old observations" do
      now = DateTime.utc_now()
      three_hours_ago = DateTime.add(now, -10_800, :second)

      result = UsageSnapshot.format_freshness(:stale, three_hours_ago)
      assert String.contains?(result, "h ago")
    end
  end

  describe "snapshot struct invariants" do
    test "snapshot struct can be created with all fields" do
      now = DateTime.utc_now()

      snapshot = %UsageSnapshot{
        agent_id: "agent-123",
        backend: :codex,
        context_occupancy: %{used_tokens: 1000, window_tokens: 4000, pressure: nil},
        cumulative_metrics: %{
          input: 10_000,
          output: 5000,
          cached_input: 3000,
          uncached_input: 7000,
          cached_proportion: 0.3
        },
        scope: :session,
        scope_id: "session-xyz",
        observed_at: now,
        freshness_assessment: :current
      }

      assert snapshot.agent_id == "agent-123"
      assert snapshot.backend == :codex
      assert snapshot.scope == :session
      assert snapshot.freshness_assessment == :current
    end

    test "snapshot with unknown dimensions preserves structure" do
      _now = DateTime.utc_now()

      snapshot = %UsageSnapshot{
        agent_id: "agent-123",
        backend: :codex,
        context_occupancy: nil,
        cumulative_metrics: %{
          input: {:unknown, :not_reported},
          output: 5000,
          cached_input: {:unknown, :not_reported},
          uncached_input: {:unknown, :insufficient_data},
          cached_proportion: {:unknown, :missing_input}
        },
        scope: :attempt,
        scope_id: "attempt-abc",
        observed_at: nil,
        freshness_assessment: :unknown
      }

      # Critical: unknowns in the struct should remain as tuples, never become zeros
      assert match?({:unknown, _}, snapshot.cumulative_metrics.input)
      assert match?({:unknown, _}, snapshot.cumulative_metrics.cached_input)
      refute snapshot.cumulative_metrics.input == 0
      refute snapshot.cumulative_metrics.cached_input == 0
    end
  end
end
