defmodule Aiur.Orchestrator.TokenAccountingTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{State, TokenAccounting}

  test "parses non-negative numeric token values and ignores invalid ones" do
    now = DateTime.utc_now()
    entry = %{agent_input_tokens: 0, agent_output_tokens: 0, agent_total_tokens: 0, session_id: nil}

    {updated, _delta} =
      TokenAccounting.integrate_codex_update(entry, %{
        event: :turn_completed,
        timestamp: now,
        payload: %{method: "turn/completed", usage: %{input_tokens: "7", output_tokens: "-1", total_tokens: "nope"}}
      })

    assert updated.agent_input_tokens == 7
    assert updated.agent_output_tokens == 0
    assert updated.agent_total_tokens == 0
  end

  test "prefers cumulative usage and preserves highwater deltas" do
    now = DateTime.utc_now()

    entry = %{
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      agent_last_reported_input_tokens: 0,
      agent_last_reported_output_tokens: 0,
      agent_last_reported_total_tokens: 0,
      session_id: nil
    }

    payload = %{
      "tokenUsage" => %{"total" => %{input_tokens: 10, output_tokens: 5, total_tokens: 15}},
      method: "turn/completed",
      usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
    }

    {updated, _delta} =
      TokenAccounting.integrate_codex_update(entry, %{event: :turn_completed, timestamp: now, payload: payload})

    assert {updated.agent_input_tokens, updated.agent_output_tokens, updated.agent_total_tokens} == {10, 5, 15}

    {again, delta} =
      TokenAccounting.integrate_codex_update(updated, %{
        event: :turn_completed,
        timestamp: now,
        payload: %{method: "turn/completed", usage: %{input_tokens: 2, output_tokens: 1, total_tokens: 3}}
      })

    assert {delta.input_tokens, delta.output_tokens, delta.total_tokens} == {0, 0, 0}
    assert {again.agent_input_tokens, again.agent_output_tokens, again.agent_total_tokens} == {10, 5, 15}
  end

  test "adds token deltas from nil totals and accepts only recognizable rate-limit maps" do
    state = %State{agent_totals: nil, agent_rate_limits: nil}
    delta = %{input_tokens: 2, output_tokens: 3, total_tokens: 5}

    assert TokenAccounting.apply_agent_token_delta(state, delta).agent_totals == %{
             input_tokens: 2,
             output_tokens: 3,
             total_tokens: 5,
             seconds_running: 0
           }

    assert TokenAccounting.apply_agent_rate_limits(
             state,
             %{rate_limits: %{primary: %{remaining: 1}}}
           ).agent_rate_limits == nil

    assert TokenAccounting.apply_agent_rate_limits(state, %{
             rate_limits: %{limit_id: "primary", primary: %{remaining: 1}}
           }).agent_rate_limits == %{limit_id: "primary", primary: %{remaining: 1}}
  end

  test "completion totals include a paused interval" do
    now = DateTime.utc_now()
    state = %State{agent_totals: nil}

    entry = %{
      started_at: DateTime.add(now, -120, :second),
      paused_at: DateTime.add(now, -60, :second)
    }

    assert TokenAccounting.record_session_completion_totals(state, entry).agent_totals.seconds_running in 119..121
  end
end
