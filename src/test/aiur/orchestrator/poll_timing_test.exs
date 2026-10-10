defmodule Aiur.Orchestrator.PollTimingTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias Aiur.Orchestrator.PollTiming

  test "successful candidate polls report boot elapsed time even after an earlier failure" do
    state = %{poll_cycles_completed: 1}
    log = capture_log(fn -> assert PollTiming.complete(state, {:ok, [:issue], %{}}) == state end)
    assert log =~ "Dispatch candidate poll completed boot_elapsed_ms="
    assert log =~ "cycle=2 issue_count=1"
    assert [_, elapsed] = Regex.run(~r/boot_elapsed_ms=(\d+)/, log)
    assert String.to_integer(elapsed) >= 0
    assert capture_log(fn -> assert PollTiming.complete(state, {:error, :unavailable}) == state end) == ""
  end
end
