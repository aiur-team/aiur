defmodule Aiur.PartitionShiftProbeTest do
  @moduledoc """
  Probe for #2560 (half one, still open): `mix test --partitions` shards
  round-robin over the *sorted* file list, so inserting one file moves every
  file that sorts after it into a different partition.

  This file is deliberately empty of behaviour and sits at the exact path PR
  #2567 adds. If `coverage (2/4)` reproduces #2567's `Aiur.ApplicationTest`
  supervision-topple on this branch, those failures are a function of the file
  count, not of #2567's diff.
  """

  use ExUnit.Case, async: false

  test "asserts nothing; it exists only to shift the partition boundaries" do
    assert :ok == :ok
  end
end
