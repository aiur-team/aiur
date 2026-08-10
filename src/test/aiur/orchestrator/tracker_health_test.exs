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

  # GitHub's X-Poll-Interval is a floor ("do not poll faster than this"), not a
  # target. Every successful firehose poll records it — 60s by default — so
  # treating it as the interval outright made `polling.interval_seconds` dead
  # config for any value above 60s, silently defeating the widening this epic
  # exists to deliver.
  test "a configured interval wider than GitHub's floor still wins" do
    state = %State{poll_interval_ms: 120_000, github_poll_delays: %{firehose: 60_000}}

    assert TrackerHealth.next_poll_delay_ms(state) == 120_000
  end

  test "GitHub's floor still wins when it is wider than the configured interval" do
    state = %State{poll_interval_ms: 30_000, github_poll_delays: %{firehose: 60_000}}

    assert TrackerHealth.next_poll_delay_ms(state) == 60_000
  end

  test "a rate-limit backoff longer than the configured interval is still respected" do
    state = %State{poll_interval_ms: 120_000, github_poll_delays: %{firehose: 60_000, comments: 900_000}}

    assert TrackerHealth.next_poll_delay_ms(state) == 900_000
  end
end
