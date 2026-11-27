defmodule Aiur.Executor.HarnessStateTest do
  use ExUnit.Case, async: true

  alias Aiur.Executor.HarnessState

  @now ~U[2026-11-20 12:00:00Z]

  test "reduces lifecycle events and preserves state for unknown notifications" do
    state = %HarnessState{}
    assert HarnessState.reduce(state, event("SessionStart"), @now).state == :idle
    working = HarnessState.reduce(state, event("UserPromptSubmit"), @now)
    assert working.state == :working
    assert HarnessState.reduce(working, event("Notification", notification_type: "unverified"), @now).state == :working
    assert HarnessState.reduce(working, event("Stop", stop_hook_active: true), @now).state == :working
    assert HarnessState.reduce(working, event("StopFailure"), @now).state == :idle
    assert HarnessState.reduce(working, event("StopFailure", reason: "failed"), @now).last_error == "failed"
    assert HarnessState.reduce(working, event("SessionEnd"), @now).state == :ended
  end

  test "ignores older events and expires to unknown with last known state" do
    later = DateTime.add(@now, 10, :second)
    state = HarnessState.reduce(%HarnessState{}, event("UserPromptSubmit", observed_at: later), later)
    assert HarnessState.reduce(state, event("SessionEnd"), @now).state == :working
    expired = HarnessState.tick(state, DateTime.add(later, 601, :second))
    assert expired.state == :unknown
    assert expired.last_known == :working
  end

  test "snapshot renders age and distinguishes unknown and stale freshness" do
    unknown = HarnessState.snapshot(%HarnessState{}, @now)
    assert %{state: :unknown, age_ms: nil, freshness: :unknown} = unknown

    working = HarnessState.reduce(%HarnessState{}, event("UserPromptSubmit"), @now)
    snapshot = HarnessState.snapshot(working, DateTime.add(@now, 61, :second))
    assert snapshot.age_ms == 61_000
    assert snapshot.freshness == :stale
  end

  defp event(name, opts \\ []) do
    %{event: name, observed_at: Keyword.get(opts, :observed_at, @now), stop_hook_active: Keyword.get(opts, :stop_hook_active, false)}
    |> Map.merge(Map.new(Keyword.delete(opts, :observed_at)))
  end
end
