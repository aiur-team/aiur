defmodule Aiur.Muse.EventNormalizerTest do
  use ExUnit.Case, async: true

  alias Aiur.Muse.CodingAgent
  alias Aiur.Orchestrator.TokenAccounting

  test "native cumulative usage reaches shared token accounting once without adding per-turn usage" do
    now = DateTime.utc_now()
    raw = token_frame("session-a", "stream-a", 1, 90, 10)
    event = %{event: :notification, timestamp: now, muse_session_id: "session-a", payload: raw}
    normalized = CodingAgent.normalize_event(event)

    assert normalized.payload == raw
    assert normalized.accounting_usage == %{input_tokens: 90, output_tokens: 10, total_tokens: 100}
    assert normalized.usage_epoch == {"session-a", "stream-a"}

    {started, _} = TokenAccounting.integrate_codex_update(entry(), %{event: :session_started, timestamp: now, session_id: "session-a-turn-1", thread_id: "session-a"})
    {first, first_delta} = TokenAccounting.integrate_codex_update(started, normalized)
    assert {first_delta.input_tokens, first_delta.output_tokens, first_delta.total_tokens} == {90, 10, 100}

    completion = %{
      event: :notification,
      timestamp: now,
      muse_session_id: "session-a",
      payload: %{"method" => "turn/completed", "params" => %{"usage" => %{"inputTokens" => 90, "outputTokens" => 10}}}
    }

    completion = CodingAgent.normalize_event(completion)
    assert completion.usage_source == :cumulative_only
    {after_completion, completion_delta} = TokenAccounting.integrate_codex_update(first, completion)
    assert {completion_delta.input_tokens, completion_delta.output_tokens, completion_delta.total_tokens} == {0, 0, 0}
    assert after_completion.agent_total_tokens == 100

    {replayed, replay_delta} = TokenAccounting.integrate_codex_update(after_completion, normalized)
    assert replay_delta.total_tokens == 0
    {next, next_delta} = TokenAccounting.integrate_codex_update(replayed, CodingAgent.normalize_event(%{event | payload: token_frame("session-a", "stream-a", 2, 125, 15)}))
    assert {next_delta.input_tokens, next_delta.output_tokens, next_delta.total_tokens} == {35, 5, 40}
    assert next.agent_total_tokens == 140
  end

  test "a new native counter epoch adds its own cumulative total" do
    now = DateTime.utc_now()

    event = fn session, stream, input ->
      CodingAgent.normalize_event(%{event: :notification, timestamp: now, muse_session_id: session, payload: token_frame(session, stream, 1, input, 0)})
    end

    {first, _} = TokenAccounting.integrate_codex_update(entry(), event.("session-a", "stream-a", 100))
    {second, delta} = TokenAccounting.integrate_codex_update(first, event.("session-b", "stream-b", 25))
    assert delta.total_tokens == 25
    assert second.agent_total_tokens == 125
  end

  test "context occupancy preserves unknown capacity and rejects foreign session events" do
    now = DateTime.utc_now()
    {started, _} = TokenAccounting.integrate_codex_update(entry(), %{event: :session_started, timestamp: now, session_id: "session-a-turn-1", thread_id: "session-a"})
    payload = %{"method" => "session/contextUsage", "params" => %{"sessionId" => "session-a", "usedTokens" => 150, "pressure" => "warning"}}
    event = %{event: :notification, timestamp: now, muse_session_id: "session-a", payload: payload}
    normalized = CodingAgent.normalize_event(event)
    assert normalized.payload == payload
    assert normalized.context_usage.window_tokens == nil
    assert normalized.context_usage.used_percent == nil

    {unknown, _} = TokenAccounting.integrate_codex_update(started, normalized)
    assert unknown.context_usage.used_tokens == 150
    assert unknown.context_usage.used_percent == nil

    known = CodingAgent.normalize_event(%{event | payload: put_in(payload, ["params", "windowTokens"], 300)})
    {updated, _} = TokenAccounting.integrate_codex_update(unknown, known)
    assert updated.context_usage.used_percent == 50.0

    foreign = CodingAgent.normalize_event(%{event | payload: put_in(payload, ["params", "sessionId"], "session-b")})
    refute Map.has_key?(foreign, :context_usage)
    {unchanged, _} = TokenAccounting.integrate_codex_update(updated, foreign)
    assert unchanged.context_usage == updated.context_usage
  end

  defp entry do
    %{
      session_id: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      agent_last_reported_input_tokens: 0,
      agent_last_reported_output_tokens: 0,
      agent_last_reported_total_tokens: 0
    }
  end

  defp token_frame(session, stream, sequence, input, output) do
    %{
      "method" => "session/tokenUsage",
      "emittedAtMs" => 1_780_000_000_000,
      "params" => %{
        "sessionId" => session,
        "turnId" => "turn-#{sequence}",
        "viewCursor" => "cursor-#{sequence}",
        "promptTokens" => input,
        "totalTokens" => input + output,
        "usage" => %{"inputTokens" => input, "outputTokens" => output},
        "cumulative" => %{"promptTokens" => input, "outputTokens" => output, "totalTokens" => input + output},
        "sourceRange" => %{"stream" => %{"id" => stream, "kind" => "session"}, "last" => %{"id" => "record-#{sequence}", "sequence" => sequence}}
      }
    }
  end
end
