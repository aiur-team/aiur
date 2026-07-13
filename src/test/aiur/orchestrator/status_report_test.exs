defmodule Aiur.Orchestrator.StatusReportTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{State, StatusReport}

  test "calculates the remaining poll interval" do
    assert StatusReport.next_poll_in_ms(nil, 10) == nil
    assert StatusReport.next_poll_in_ms(20, 10) == 10
    assert StatusReport.next_poll_in_ms(5, 10) == 0
  end

  test "identifies GitHub budget pacing in operator poll status" do
    throttle = %{reason: :github_rate_budget, delay_ms: 60_000, reset_in_ms: 120_000, remaining: 50, limit: 5_000}
    state = %State{poll_interval_ms: 30_000, next_poll_due_at_ms: 70_000}

    assert %{
             checking?: false,
             next_poll_in_ms: 60_000,
             poll_interval_ms: 30_000,
             throttle: ^throttle
           } =
             StatusReport.polling_status(state,
               now_ms: 10_000,
               include_interval?: true,
               budget_status_fun: fn -> throttle end
             )
  end
end
