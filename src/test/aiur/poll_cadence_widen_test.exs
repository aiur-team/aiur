defmodule Aiur.PollCadenceWidenTest do
  use ExUnit.Case, async: true

  alias Aiur.PollCadence
  alias Aiur.Webhooks.IntervalPolicy

  # Regression guard for the pre-extraction rounding and floor behavior.
  test "widen preserves the original interval policy arithmetic" do
    for base <- [1, 3, 101, 60_000], factor <- [-2, 0, 0.9, 1, 1.005, 1.5, 4] do
      expected = base |> Kernel.*(factor) |> round() |> max(base)
      assert PollCadence.widen(base, factor) == expected
      assert IntervalPolicy.widen(base, factor) == expected
    end
  end

  test "widen_factor preserves the original floor and invalid-value behavior" do
    for {input, expected} <- [{nil, 1.0}, {"2", 1.0}, {0, 1.0}, {1, 1.0}, {2, 2.0}, {1.25, 1.25}] do
      assert PollCadence.widen_factor(widen_factor: input) === expected
      assert IntervalPolicy.widen_factor(widen_factor: input) === expected
    end
  end
end
