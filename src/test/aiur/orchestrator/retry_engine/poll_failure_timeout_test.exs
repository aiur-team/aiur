defmodule Aiur.Orchestrator.RetryEngine.PollFailureTimeoutTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.RetryEngine.PollFailure
  alias Aiur.Orchestrator.State

  test "claim release names a before_run timeout as its cause" do
    reason = {:workspace_hook_timeout, "before_run", 500}

    log =
      capture_log(fn ->
        PollFailure.emit_claim_released_alert(%State{}, "issue-hook-timeout", "MT-HOOK-TIMEOUT", 2, reason, %{})
      end)

    assert log =~ "reason=workspace_hook_timeout"
    assert log =~ "tracker_error={:workspace_hook_timeout, \"before_run\", 500}"
    assert log =~ "orchestrator.claim_released"
  end
end
