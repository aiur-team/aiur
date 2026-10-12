defmodule Aiur.Experiments.CoverageTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Coverage
  @window %{start: ~U[2026-10-01 00:00:00Z], end: ~U[2026-10-07 00:00:00Z]}

  test "capture starting after the window preserves covered_from" do
    assert %{state: :partial, covered_from: ~U[2026-10-04 00:00:00Z]} = Coverage.classify([], [], @window, ~U[2026-10-04 00:00:00Z])
  end

  test "a missing required fact is not captured regardless of samples" do
    assert %{state: :not_captured, missing: ["cohort"]} = Coverage.classify(["cohort"], ["pr_opened"], @window, @window.start)
  end

  test "zero observations remain captured when the source covered the window" do
    assert %{state: :captured} = Coverage.classify([], [], @window, @window.start)
    assert %{state: :captured} = Coverage.classify([], [], @window, nil)
    assert %{state: :unavailable} = Coverage.classify([], [], @window, :unavailable)
  end
end
