defmodule Aiur.CurrentRunProjection.ValueTest do
  use ExUnit.Case, async: true

  alias Aiur.CurrentRunProjection.Value

  describe "get/3" do
    test "reads an atom key from a map" do
      assert Value.get(%{count: 3}, :count) == 3
    end

    test "falls back to the string spelling of the key" do
      assert Value.get(%{"count" => 7}, :count) == 7
    end

    test "the atom key wins over the string spelling when both exist" do
      assert Value.get(%{:count => 1, "count" => 2}, :count) == 1
    end

    test "a missing key returns the default, and the default defaults to an empty map" do
      assert Value.get(%{}, :count, :none) == :none
      assert Value.get(%{}, :count) == %{}
    end

    test "a non-map value returns the default rather than raising" do
      assert Value.get(nil, :count, 0) == 0
      assert Value.get([:not, :a, :map], :count, 0) == 0
    end
  end

  describe "health/1" do
    test "healthy statuses" do
      for status <- [:healthy, :available, :writable] do
        assert Value.health(status) == :healthy
      end
    end

    test "degraded statuses, including tagged tuples" do
      for status <- [:degraded, :stale, :partial, :unknown] do
        assert Value.health(status) == :degraded
      end

      assert Value.health({:degraded, :disk_full}) == :degraded
      assert Value.health({:corrupt, 42, :bad_json}) == :degraded
    end

    test "unavailable statuses, including anything unrecognized" do
      assert Value.health({:unavailable, :enoent}) == :unavailable
      assert Value.health(:something_else) == :unavailable
      assert Value.health(nil) == :unavailable
    end

    test "unwraps a status map recursively" do
      assert Value.health(%{status: :available}) == :healthy
      assert Value.health(%{status: {:unavailable, :enoent}}) == :unavailable
    end
  end

  describe "freshness/1" do
    test "known freshness states pass through" do
      for status <- [:fresh, :stale, :unknown, :unavailable, :partial] do
        assert Value.freshness(status) == status
      end
    end

    test "unwraps a status map and defaults anything unrecognized to :unknown" do
      assert Value.freshness(%{status: :stale}) == :stale
      assert Value.freshness(:garbage) == :unknown
      assert Value.freshness(nil) == :unknown
    end
  end

  describe "worse_freshness/1" do
    test "picks the worst state by rank: unavailable < stale < unknown < partial < fresh" do
      assert Value.worse_freshness([:fresh, :stale]) == :stale
      assert Value.worse_freshness([:fresh, :partial]) == :partial
      assert Value.worse_freshness([:partial, :unknown]) == :unknown
      assert Value.worse_freshness([:unknown, :stale]) == :stale
      assert Value.worse_freshness([:stale, :unavailable]) == :unavailable
      assert Value.worse_freshness([:fresh, :fresh]) == :fresh
    end

    test "an empty list is :unknown, and unrecognized entries rank as :unknown" do
      assert Value.worse_freshness([]) == :unknown
      assert Value.worse_freshness([:garbage, :fresh]) == :unknown
      assert Value.worse_freshness([%{status: :unavailable}, :fresh]) == :unavailable
    end
  end
end
