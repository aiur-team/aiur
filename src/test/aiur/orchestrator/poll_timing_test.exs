defmodule Aiur.Orchestrator.PollTimingTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias Aiur.Orchestrator.PollTiming

  test "the first successful candidate poll reports boot elapsed time" do
    state = %{poll_cycles_completed: 0}
    log = capture_log(fn -> assert PollTiming.complete(state, {:ok, [:issue], %{}}) == state end)
    assert log =~ "Dispatch candidate poll completed boot_elapsed_ms="
    assert log =~ "issue_count=1"
    assert [_, elapsed] = Regex.run(~r/boot_elapsed_ms=(\d+)/, log)
    assert String.to_integer(elapsed) >= 0
  end

  test "later polls and failed polls stay silent" do
    later = %{poll_cycles_completed: 1}
    assert capture_log(fn -> assert PollTiming.complete(later, {:ok, [:issue], %{}}) == later end) == ""
    first = %{poll_cycles_completed: 0}
    assert capture_log(fn -> assert PollTiming.complete(first, {:error, :unavailable}) == first end) == ""
  end
end
