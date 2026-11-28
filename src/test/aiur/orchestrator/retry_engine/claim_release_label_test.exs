defmodule Aiur.Orchestrator.RetryEngine.ClaimReleaseLabelTest do
  # A released claim after every agent attempt failed was reported as
  # "after 3 tracker failures (reason=tracker_retry_exhausted)", which sent
  # operators to GitHub for what was a provider refusal (open-game-maker #854).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Orchestrator.RetryEngine.PollFailure
  alias Aiur.Orchestrator.State

  defp release_log(reason) do
    capture_log(fn -> PollFailure.emit_claim_released_alert(%State{auto_resume: %{}}, "854", "854", 3, reason, %{}) end)
  end

  test "agent failure exhaustion is named as such" do
    exhausted = {%RuntimeError{message: "Agent run failed for issue_id=854: {:http_error, 402, \"limit\"}"}, []}
    log = release_log(exhausted)

    assert log =~ "reason=agent_retry_exhausted"
    assert log =~ "after 3 failed agent attempts"
    refute log =~ "tracker failures"
  end

  test "a tracker failure keeps its tracker label" do
    log = release_log({:github_api_status, 403})

    assert log =~ "reason=tracker_retry_exhausted"
    assert log =~ "after 3 tracker failures"
  end
end
