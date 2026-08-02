defmodule Aiur.Orchestrator.StatusReportTest do
  use ExUnit.Case, async: true

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
end
