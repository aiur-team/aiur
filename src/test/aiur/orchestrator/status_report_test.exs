defmodule Aiur.Orchestrator.StatusReportTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.StatusReport

  test "calculates the remaining poll interval" do
    assert StatusReport.next_poll_in_ms(nil, 10) == nil
    assert StatusReport.next_poll_in_ms(20, 10) == 10
    assert StatusReport.next_poll_in_ms(5, 10) == 0
  end
end
