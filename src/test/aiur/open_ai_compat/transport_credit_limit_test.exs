defmodule Aiur.OpenAICompat.TransportCreditLimitTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.OpenAICompat.{OutputTokens, Transport}

  # The exact shape OpenRouter answers with when the key cannot cover the
  # request's output-token reservation (#7514).
  @credit_refusal "This request requires more credits, or fewer max_tokens. You requested up to 16000 tokens, " <>
                    "but can only afford 4096. To increase, visit https://openrouter.ai/settings/credits and " <>
                    "upgrade to a paid account."

  defp refusal(message), do: {:ok, %{status: 402, body: %{"error" => %{"message" => message, "code" => 402}}, headers: %{}}}

  defp ok(body \\ %{"id" => "ok", "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done."}}]}) do
    response(body)
  end

  defp config(request_fun, extra \\ %{}) do
    Map.merge(
      %{
        backend: :openrouter,
        base_url: "https://openrouter.ai/api/v1",
        api_key: "secret",
        model: "deepseek/deepseek-v4-flash",
        transport: :chat_completions,
        quirks: %{local_concurrency_limit: false},
        request_fun: request_fun
      },
      extra
    )
  end

  test "sends the default output cap as max_tokens" do
    parent = self()

    recorder = fn request ->
      send(parent, {:request, request})
      ok()
    end

    assert {:ok, _completion} = Transport.complete(config(recorder), [], [])

    assert [request] = collect_requests(1)
    assert request.json["max_tokens"] == OutputTokens.default()
  end

  test "honors agent.backend_configs.<backend>.max_output_tokens" do
    parent = self()

    recorder = fn request ->
      send(parent, {:request, request})
      ok()
    end

    assert {:ok, _completion} = Transport.complete(config(recorder, %{max_output_tokens: 8_000}), [], [])

    assert [request] = collect_requests(1)
    assert request.json["max_tokens"] == 8_000
  end

  test "the responses transport caps max_output_tokens" do
    parent = self()

    recorder = fn request ->
      send(parent, {:request, request})
      ok(%{"id" => "resp-1", "status" => "completed", "output" => []})
    end

    assert {:ok, _completion} = Transport.complete(config(recorder, %{transport: :responses}), [], [])

    assert [request] = collect_requests(1)
    assert request.json["max_output_tokens"] == OutputTokens.default()
    refute Map.has_key?(request.json, "max_tokens")
  end

  test "a credit refusal retries once with the cap the provider says the balance affords" do
    parent = self()
    queue = start_supervised!({Agent, fn -> [refusal(@credit_refusal), ok()] end})

    assert {:ok, _completion} = Transport.complete(config(queue_fun(queue, parent)), [], [])

    assert [first, second] = collect_requests(2)
    assert first.json["max_tokens"] == 16_000
    assert second.json["max_tokens"] == 4_096
  end

  test "a credit refusal without an affordable figure retries at half the cap" do
    parent = self()

    queue =
      start_supervised!({Agent, fn -> [refusal("This request requires more credits, or fewer max_tokens."), ok()] end})

    assert {:ok, _completion} = Transport.complete(config(queue_fun(queue, parent)), [], [])

    assert [first, second] = collect_requests(2)
    assert first.json["max_tokens"] == 16_000
    assert second.json["max_tokens"] == 8_000
  end

  test "a second credit refusal pauses the route instead of failing the turn" do
    parent = self()
    queue = start_supervised!({Agent, fn -> [refusal(@credit_refusal), refusal(@credit_refusal), ok()] end})

    assert {:error, :credit_limited} = Transport.complete(config(queue_fun(queue, parent)), [], [])

    assert [first, second] = collect_requests(2)
    assert first.json["max_tokens"] == 16_000
    assert second.json["max_tokens"] == 4_096
  end

  test "a 402 that is not about credits or max_tokens keeps its error and is not retried" do
    parent = self()
    queue = start_supervised!({Agent, fn -> [refusal("Payment method declined."), ok()] end})

    assert {:error, {:http_error, 402, "Payment method declined."}} =
             Transport.complete(config(queue_fun(queue, parent)), [], [])

    assert [_only] = collect_requests(1)
  end

  test "a completion that stops on the cap is retried once with a larger cap" do
    parent = self()

    queue =
      start_supervised!(
        {Agent,
         fn ->
           [
             ok(%{"id" => "truncated", "choices" => [%{"finish_reason" => "length", "message" => %{"role" => "assistant", "content" => "partial"}}]}),
             ok()
           ]
         end}
      )

    assert {:ok, completion} = Transport.complete(config(queue_fun(queue, parent)), [], [])
    assert completion.finish_reason == "stop"

    assert [first, second] = collect_requests(2)
    assert first.json["max_tokens"] == 16_000
    assert second.json["max_tokens"] == 32_000
  end

  test "a completion that is truncated twice stays an incomplete-response error" do
    parent = self()

    truncated =
      ok(%{"id" => "truncated", "choices" => [%{"finish_reason" => "length", "message" => %{"role" => "assistant", "content" => "partial"}}]})

    queue = start_supervised!({Agent, fn -> [truncated, truncated] end})

    assert {:error, {:incomplete_provider_response, "length"}} =
             Transport.complete(config(queue_fun(queue, parent)), [], [])

    assert [_first, _second] = collect_requests(2)
  end
end
