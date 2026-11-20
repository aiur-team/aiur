defmodule Aiur.ControlCLI.OptimisticReasonTest do
  use ExUnit.Case, async: true

  alias Aiur.ControlCLI.Reasons

  test "optimistic share declines name the occupied slots and cap" do
    assert Reasons.format_reason({:optimistic_share, %{running: 4, cap: 4, share: 0.5}}) == "optimistic share full (4/4)"
    assert Reasons.format_reason({:optimistic_share, %{running: 0, cap: 0, share: 0.0}}) == "optimistic share full (0/0)"
  end

  test "resume capacity refusal names the configured cap or AIMD envelope" do
    assert Reasons.format_reason({:max_concurrent_agents_reached, %{used: 6, active: 0, paused_holds: 6, limit: 6, max: 8}}) ==
             "max concurrent agents reached: 6 of 6 slots used (0 active, 6 held by paused entries; binding: AIMD envelope=6 (configured cap=8))"

    assert Reasons.format_reason({:max_concurrent_agents_reached, %{used: 8, active: 0, paused_holds: 8, limit: 8, max: 8}}) ==
             "max concurrent agents reached: 8 of 8 slots used (0 active, 8 held by paused entries; binding: configured cap=8)"
  end
end
