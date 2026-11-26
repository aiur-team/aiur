defmodule Aiur.Orchestrator.NativeHoldTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{RuntimeWatchdog, State, TokenAccounting}

  test "held event exempts a silent worker from stall and duration checks until resolution" do
    now = DateTime.utc_now()

    entry = %{
      session_id: "thread-turn",
      identifier: "979",
      started_at: DateTime.add(now, -120, :second),
      pid: self(),
      ref: nil,
      issue: %Issue{id: "979", identifier: "979", state: "in-progress"},
      control: %{status: :working, can_interrupt: true}
    }

    update = %{event: :native_question_held, timestamp: now, native_ref: "first", decision_id: "d1", since: now}
    {held, _delta} = TokenAccounting.integrate_codex_update(entry, update)
    assert held.native_hold == %{decision_id: "d1", since: now}
    assert held.native_holds == %{"first" => %{decision_id: "d1", since: now}}
    # Make ordinary activity stale too: an accounting event must not mask a missing stall exemption.
    held = Map.put(held, :last_codex_timestamp, entry.started_at)
    state = %State{running: %{"979" => held}}
    assert RuntimeWatchdog.apply_stall_check(state, 1) == state
    assert RuntimeWatchdog.maybe_pause_overrunning_entry(state, "979", held, now, 1) == state
    assert RuntimeWatchdog.apply_overrun_check(state, 1) == state

    {resolved, _delta} = TokenAccounting.integrate_codex_update(held, %{update | event: :native_question_resolved})
    assert resolved.native_hold == nil
    assert resolved.native_holds == %{}
    assert RuntimeWatchdog.overrunning_entry?(resolved, now, 1)
  end

  test "resolving one request preserves the other hold and unrelated accounting preserves both" do
    now = DateTime.utc_now()
    entry = %{session_id: "thread-turn"}
    update = %{event: :native_question_held, timestamp: now, native_ref: "first", decision_id: "d1", since: now}
    {first, _} = TokenAccounting.integrate_codex_update(entry, update)
    {both, _} = TokenAccounting.integrate_codex_update(first, %{update | native_ref: "second", decision_id: "d2"})
    {unchanged, _} = TokenAccounting.integrate_codex_update(both, %{event: :notification, timestamp: now})
    assert unchanged.native_holds == both.native_holds
    assert map_size(unchanged.native_holds) == 2
    {one, _} = TokenAccounting.integrate_codex_update(unchanged, %{update | event: :native_question_resolved})
    assert one.native_holds == %{"second" => %{decision_id: "d2", since: now}}
    assert one.native_hold == %{decision_id: "d2", since: now}
    {none, _} = TokenAccounting.integrate_codex_update(one, %{update | event: :native_question_resolved, native_ref: "second"})
    assert none.native_hold == nil
  end
end
