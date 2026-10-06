defmodule Aiur.Muse.UsageTest do
  use ExUnit.Case, async: true

  alias Aiur.Muse.Usage
  alias Aiur.Usage.Headless.Context
  alias Aiur.Usage.Headless.Muse.SessionUsage

  @ingested_at ~U[2026-09-27 12:00:00Z]

  test "session cumulative totals are authoritative once across replay and attempt change" do
    first = token_event(1, 70, 12, 70, 12)
    second = token_event(2, 95, 15, 165, 27)

    assert [{:ok, first_envelope}] = SessionUsage.extract(first, nil, context("attempt-a"), @ingested_at)
    assert [{:ok, replay_envelope}] = SessionUsage.extract(first, nil, context("attempt-b"), @ingested_at)
    assert [{:ok, second_envelope}] = SessionUsage.extract(second, nil, context("attempt-b"), @ingested_at)

    assert first_envelope.measurement_kind == :absolute
    assert first_envelope.counter_scope == :session
    assert first_envelope.tokens.input == 70
    assert first_envelope.tokens.output == 12
    assert first_envelope.tokens.provider_reported_total == 82
    assert first_envelope.tokens.cached_input == nil
    assert first_envelope.tokens.reasoning_output == nil
    assert first_envelope.cost == nil
    assert first_envelope.idempotency_key == replay_envelope.idempotency_key
    assert first_envelope.counter_epoch == replay_envelope.counter_epoch
    assert first_envelope.attribution.attempt_id != replay_envelope.attribution.attempt_id
    assert second_envelope.counter_epoch == first_envelope.counter_epoch
    assert second_envelope.tokens.provider_reported_total == 192
    assert second_envelope.tokens.provider_reported_total - first_envelope.tokens.provider_reported_total == 110
  end

  test "child stream and cross-session events cannot be added to parent counter" do
    child = put_in(token_event(1, 10, 2, 10, 2), ["params", "sourceRange", "stream", "kind"], "child")
    other = put_in(token_event(1, 10, 2, 10, 2), ["params", "sessionId"], "other-session")

    for event <- [child, other] do
      assert [{:coverage, %{class: :ambiguous_measurement_semantics, field: :counter_scope}}] =
               SessionUsage.extract(event, nil, context("attempt-a"), @ingested_at)
    end
  end

  test "malformed counted-once fields are rejected instead of silently summed" do
    event = put_in(token_event(1, 10, 2, 10, 2), ["params", "totalTokens"], 13)
    assert {:error, :invalid_token_usage} = Usage.token_notification(event)
  end

  test "context occupancy stays unknown without usable capacity" do
    event = %{
      "method" => "session/contextUsage",
      "params" => %{"sessionId" => "session-a", "usedTokens" => 150, "pressure" => "warning"}
    }

    assert {:ok, %{used_tokens: 150, window_tokens: nil, used_percent: nil}} = Usage.context_notification(event)

    assert {:ok, %{used_percent: nil}} =
             Usage.context_notification(put_in(event, ["params", "windowTokens"], 0))

    assert {:ok, %{used_percent: 150.0}} =
             Usage.context_notification(put_in(event, ["params", "windowTokens"], 100))
  end

  defp context(attempt_id) do
    %Context{
      run_id: "run-u5",
      session_id: "session-a",
      attempt_id: attempt_id,
      agent_family: :muse,
      backend: :app_server,
      transport: :app_server,
      source_sequence: 1,
      account_generation: %{
        provider: :muse,
        backend: :app_server,
        generation: nil,
        freshness: :unknown,
        health: :unknown,
        reason: :untrusted_lifecycle
      }
    }
  end

  defp token_event(sequence, turn_input, turn_output, cumulative_input, cumulative_output) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/tokenUsage",
      "emittedAtMs" => 1_780_000_000_000,
      "params" => %{
        "sessionId" => "session-a",
        "turnId" => "turn-#{sequence}",
        "viewCursor" => "cursor-#{sequence}",
        "promptTokens" => turn_input,
        "totalTokens" => turn_input + turn_output,
        "usage" => %{
          "inputTokens" => turn_input,
          "outputTokens" => turn_output,
          "cachedTokens" => 5,
          "cacheReadTokens" => 5,
          "reasoningTokens" => 2
        },
        "cumulative" => %{
          "promptTokens" => cumulative_input,
          "outputTokens" => cumulative_output,
          "totalTokens" => cumulative_input + cumulative_output
        },
        "sourceRange" => %{
          "stream" => %{"id" => "stream-a", "kind" => "session"},
          "last" => %{"id" => "record-#{sequence}", "sequence" => sequence}
        }
      }
    }
  end
end
