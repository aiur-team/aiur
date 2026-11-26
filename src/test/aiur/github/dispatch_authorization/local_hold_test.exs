defmodule Aiur.GitHub.DispatchAuthorization.LocalHoldTest do
  import Aiur.GitHub.DispatchAuthorization.TestFixtures
  import ExUnit.CaptureLog

  use Aiur.TestSupport

  alias Aiur.GitHub.DispatchAuthorization

  setup do
    DispatchAuthorization.clear_cache()
    :ok
  end

  test "a local hold on the provenance timeline retries before deferring dispatch" do
    parent = self()
    reset_at = DateTime.add(DateTime.utc_now(), -1, :second)
    hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
    local_hold = {:aiur, :locally_held, hold}
    events = [labeled_event(10, "agent:todo", "trusted", "2026-01-01T00:00:00Z")]

    log =
      capture_log(fn ->
        authorized =
          authorize_with_events(issue(), events, ["trusted"],
            request_fun: fn request ->
              attempt = Process.get(:dispatch_timeline_attempt, 0)
              Process.put(:dispatch_timeline_attempt, attempt + 1)
              send(parent, {:timeline_attempt, request.url})
              if attempt == 0, do: {:error, local_hold}, else: {:ok, %{status: 200, body: events}}
            end,
            local_hold_sleep_fun: fn _ms -> flunk("an expired hold must retry without sleeping") end
          )

        assert authorized.dispatch_authorized?
      end)

    refute log =~ "dispatch authorization deferred"
    assert_received {:timeline_attempt, url}
    assert url =~ "/timeline?per_page=50"
    assert_received {:timeline_attempt, ^url}
    refute_received {:timeline_attempt, _}
  end
end
