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

  test "widens a quiet source without delaying the global poll cycle" do
    state = %State{poll_interval_ms: 1_000, github_poll_delays: %{}}
    quiet = TrackerHealth.note_github_poll_quiet(state, :comments, 10_000)

    assert quiet.github_poll_delays[{:quiet, :comments}] == %{delay_ms: 2_000, next_poll_at_ms: 12_000}
    refute TrackerHealth.github_source_due?(quiet, :comments, 11_999)
    assert TrackerHealth.github_source_due?(quiet, :comments, 12_000)
    assert TrackerHealth.next_poll_delay_ms(quiet) == 1_000

    widened = TrackerHealth.note_github_poll_quiet(quiet, :comments, 12_000)
    assert widened.github_poll_delays[{:quiet, :comments}].delay_ms == 4_000
    assert TrackerHealth.note_github_poll_active(widened, :comments).github_poll_delays == %{}
  end
end
