defmodule Aiur.ControlCLI.OptimisticReasonTest do
  use ExUnit.Case, async: true

  alias Aiur.ControlCLI.Reasons

  test "optimistic share declines name the occupied slots and cap" do
    assert Reasons.format_reason({:optimistic_share, %{running: 4, cap: 4, share: 0.5}}) == "optimistic share full (4/4)"
    assert Reasons.format_reason({:optimistic_share, %{running: 0, cap: 0, share: 0.0}}) == "optimistic share full (0/0)"
  end
end
