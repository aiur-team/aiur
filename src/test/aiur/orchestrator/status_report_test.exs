defmodule Aiur.Orchestrator.StatusReportTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{State, StatusReport}

  test "calculates the remaining poll interval" do
    assert StatusReport.next_poll_in_ms(nil, 10) == nil
    assert StatusReport.next_poll_in_ms(20, 10) == 10
    assert StatusReport.next_poll_in_ms(5, 10) == 0
  end

  test "renders a retry without a current tracker snapshot" do
    due_at_ms = System.monotonic_time(:millisecond) + 240_000

    statuses =
      StatusReport.agent_statuses(%State{
        retry_attempts: %{
          "missing" => %{identifier: "repo#20", attempt: 1, due_at_ms: due_at_ms, error: "provider unavailable"}
        }
      })

    assert [%{identifier: "repo#20", state: :paused, title: nil, reason: {:transient, _, _}}] = statuses
  end

  test "gives tracker pause precedence while retaining retry metadata" do
    due_at_ms = System.monotonic_time(:millisecond) + 240_000
    paused = %{id: "paused-retry", identifier: "repo#21", state: "todo", paused: true}

    assert [status] =
             StatusReport.agent_statuses(%State{
               last_polled_issues: %{paused.id => paused},
               retry_attempts: %{
                 paused.id => %{identifier: paused.identifier, attempt: 1, due_at_ms: due_at_ms, error: "tracker 403"}
               }
             })

    assert status.tracker_paused
    assert {:paused, :label_override, {:transient, "tracker 403", _}} = status.reason
    assert {:transient, "tracker 403", _} = status.retry_reason
  end

  test "takes a bounded prewarm snapshot and handles an exited base server" do
    assert :building =
             StatusReport.prewarm_phase(fn timeout ->
               send(self(), {:repo_base_timeout, timeout})
               {:building, "/tmp/base"}
             end)

    assert_receive {:repo_base_timeout, 100}
    assert :unavailable = StatusReport.prewarm_phase(fn _timeout -> exit(:noproc) end)
  end

  test "uses one prewarm snapshot for every idle row" do
    issues =
      for id <- ["one", "two"], into: %{} do
        {id, %{id: id, identifier: "repo##{id}", state: "todo", paused: false}}
      end

    statuses =
      StatusReport.agent_statuses(%State{last_polled_issues: issues}, fn timeout ->
        send(self(), {:repo_base_status_called, timeout})
        {:building, "/tmp/base"}
      end)

    assert_receive {:repo_base_status_called, 100}
    refute_receive {:repo_base_status_called, _}
    assert Enum.all?(statuses, &(&1.reason == :prewarm_blocked))
  end

  test "status rows expose waiting and pause reasons consistently" do
    issue = %Issue{id: "paused", identifier: "repo#paused", state: "in-progress", title: "Needs input"}

    entry = %{
      identifier: issue.identifier,
      issue: issue,
      started_at: DateTime.add(DateTime.utc_now(), -900, :second),
      paused_reason: :agent_pause_request,
      control: %{status: :paused}
    }

    [status] = StatusReport.agent_statuses(%State{running: %{issue.id => entry}})

    assert status.state == :paused
    assert status.waiting_reason == :waiting_for_human
    assert status.pause_reason == :agent_pause_request
    assert status.blocked_by == []
  end

  test "idle dependency rows expose the blocker and dependency waiting reason" do
    blocker = %{id: "blocker", identifier: "repo#blocker", state: "in-progress"}
    issue = %Issue{id: "waiting", identifier: "repo#waiting", state: "todo", blocked_by: [blocker]}

    [status] = StatusReport.agent_statuses(%State{last_polled_issues: %{issue.id => issue}}, fn _ -> {:unavailable, nil} end)

    assert status.waiting_reason == :waiting_for_dependency
    assert status.blocked_by == [blocker]

    [snapshot_status] = StatusReport.snapshot_payload(%State{last_polled_issues: %{issue.id => issue}}).idle

    assert snapshot_status.waiting_reason == status.waiting_reason
    assert snapshot_status.blocked_by == status.blocked_by
  end

  test "human-wait alert threshold is episode-based and inclusive" do
    now = ~U[2026-08-11 12:00:00Z]

    refute StatusReport.waiting_for_human_alert_due?(DateTime.add(now, -599, :second), now)
    assert StatusReport.waiting_for_human_alert_due?(DateTime.add(now, -600, :second), now)
  end
end
