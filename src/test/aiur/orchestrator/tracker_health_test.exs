defmodule Aiur.Orchestrator.TrackerHealthTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{State, TrackerHealth}

  test "uses the base interval when no GitHub delay is active" do
    assert TrackerHealth.next_poll_delay_ms(%State{poll_interval_ms: 1_000, github_poll_delays: %{}}) == 1_000
  end

  test "uses the largest active GitHub delay" do
    state = %State{poll_interval_ms: 1_000, github_poll_delays: %{comments: 2_000, firehose: 3_000}}

    assert TrackerHealth.next_poll_delay_ms(state) == 3_000
  end
end
