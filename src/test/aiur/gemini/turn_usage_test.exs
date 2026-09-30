defmodule Aiur.Gemini.TurnUsageTest do
  use ExUnit.Case, async: true

  alias Aiur.Usage.Headless.{Context, Emitter}
  alias Aiur.Usage.Headless.Gemini.TurnUsage

  @now ~U[2026-09-29 16:00:00Z]

  test "Gemini 0.61.0 prompt quota produces one attributable per-turn delta" do
    context = context()
    payload = prompt_result(12, 5)

    assert [{:ok, envelope}] = TurnUsage.extract(payload, nil, context, @now)
    assert envelope.provider == :gemini
    assert envelope.measurement_kind == :delta
    assert envelope.counter_scope == :turn
    assert envelope.tokens.input == 12
    assert envelope.tokens.output == 5
    assert envelope.tokens.provider_reported_total == nil
    assert envelope.attribution.session_id == "gemini-session"
    assert envelope.attribution.turn_id == "17"
    assert envelope.cost == nil

    assert [{:ok, replay}] = TurnUsage.extract(payload, nil, context, @now)
    assert replay.idempotency_key == envelope.idempotency_key
  end

  test "unknown source version and absent quota never become fabricated zero" do
    context = context()

    assert [{:coverage, %{class: :unsupported_source_revision}}] =
             TurnUsage.extract(%{prompt_result(12, 5) | "aiurCliVersion" => "0.62.0"}, nil, context, @now)

    assert [{:coverage, %{class: :missing_usage_measurement}}] =
             TurnUsage.extract(%{prompt_result(12, 5) | "result" => %{"stopReason" => "end_turn"}}, nil, context, @now)
  end

  test "headless emitter publishes the Gemini quota through the registry chain" do
    owner = self()
    payload = prompt_result(20, 8)
    message = %{payload: payload, raw: Jason.encode!(payload), timestamp: @now}

    assert %{envelopes: [_]} =
             Emitter.observe(nil, "gemini", message, backend: "gemini", run_id: "run-2", attempt_id: "attempt-2", usage_publisher: fn envelope -> send(owner, {:gemini_usage, envelope}) end)

    assert_receive {:gemini_usage, %{tokens: %{input: 20, output: 8}, transport: :gemini_acp}}
  end

  defp context do
    {:ok, context} = Context.build(nil, "gemini", run_id: "run-1", backend: "gemini", attempt_id: "attempt-1", source_sequence: 7)
    context
  end

  defp prompt_result(input, output) do
    %{
      "method" => "session/prompt",
      "id" => 17,
      "aiurCliVersion" => "0.61.0",
      "aiurSessionId" => "gemini-session",
      "result" => %{
        "stopReason" => "end_turn",
        "_meta" => %{
          "quota" => %{
            "token_count" => %{"input_tokens" => input, "output_tokens" => output},
            "model_usage" => [
              %{
                "model" => "gemini-pro",
                "token_count" => %{
                  "input_tokens" => input,
                  "output_tokens" => output
                }
              }
            ]
          }
        }
      }
    }
  end
end
