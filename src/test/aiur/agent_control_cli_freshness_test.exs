defmodule Aiur.AgentControlCLIFreshnessTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "a stalled fleet view names the global pause start" do
    paused_at = ~U[2026-10-11 00:51:59.477172Z]

    output =
      capture_io(fn ->
        Aiur.AgentControlCLIFreshness.print(
          %{status: :stale, reason: :snapshot_stalled, age_seconds: 2_521},
          %{globally_paused: true, paused_at: paused_at}
        )
      end)

    assert output =~ "global pause active since 2026-10-11T00:51:59.477172Z"
    refute output =~ "the orchestrator has stopped publishing"
  end

  test "a snapshot timeout is not reported as an unavailable orchestrator" do
    output =
      capture_io(fn ->
        Aiur.AgentControlCLIFreshness.print(%{status: :stale, reason: :snapshot_timeout, age_seconds: 12}, nil)
      end)

    assert output =~ "the snapshot projection timed out"
    refute output =~ "the orchestrator is unavailable"
  end
end
