defmodule Aiur.OrchestratorCIUnpublishedCadenceTest do
  use Aiur.TestSupport
  import Aiur.TestSupport.CIPollerFixture

  alias Aiur.{Issue, PollCadence}
  alias Aiur.Orchestrator.{CiLifecycle, State}

  setup :ci_poller_env

  test "a recent poll is not throttled before the ci cadence is published" do
    PollCadence.forget_effective_interval_ms()
    issue = %Issue{id: "ci-unthrottled", identifier: "ci-unthrottled", state: "ci-wait", title: "Unthrottled CI poll"}
    state = %State{last_ci_poll_started_at_ms: System.monotonic_time(:millisecond)}
    parent = self()

    next =
      CiLifecycle.poll_github_ci(state,
        ci_issue_fetcher: fn _states ->
          send(parent, :ci_issues_fetched)
          {:ok, [issue]}
        end,
        ci_poller: fn targets, _opts ->
          send(parent, {:ci_targets_polled, targets})
          {:ok, %{results: [], errors: []}}
        end
      )

    assert_received :ci_issues_fetched
    assert_received {:ci_targets_polled, ["ci-unthrottled"]}
    assert next.last_ci_poll_started_at_ms != nil
  end
end
