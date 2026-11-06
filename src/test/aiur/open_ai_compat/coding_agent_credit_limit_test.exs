defmodule Aiur.OpenAICompat.CodingAgentCreditLimitTest do
  use ExUnit.Case, async: true

  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.CodingAgent.RouteFailure
  alias Aiur.OpenAICompat.{CodingAgent, OutputTokens}

  @credit_refusal "This request requires more credits, or fewer max_tokens. You requested up to 131072 tokens, " <>
                    "but can only afford 4096. To increase, visit https://openrouter.ai/settings/credits and " <>
                    "upgrade to a paid account."

  defp refusal do
    {:ok, %{status: 402, body: %{"error" => %{"message" => @credit_refusal, "code" => 402}}, headers: %{}}}
  end

  defp start(workspace, request_fun, opts \\ []) do
    CodingAgent.start_session(
      workspace,
      Keyword.merge(
        [
          backend: "openrouter",
          instance: instance([]),
          api_key_fetcher: fn _ -> "secret" end,
          request_fun: request_fun
        ],
        opts
      )
    )
  end

  test "an exhausted-key OpenRouter turn pauses the route, and the ticket is not in error", %{workspace: workspace} do
    parent = self()
    queue = start_supervised!({Agent, fn -> [refusal(), refusal()] end})

    assert {:ok, session} = start(workspace, queue_fun(queue, parent))

    # A pause, never an `{:error, _}`: the runner suspends on a pause and keeps
    # the claim, so the ticket is not moved to agent:error (#7514).
    assert {:paused, payload} = CodingAgent.run_turn(session, "Do the work", issue(), [])

    assert payload.kind == :usage_limit_exhausted
    assert payload.reason == :credit_limited
    assert payload.credit_limited == true
    assert payload.backend == "openrouter"

    assert [first, second] = collect_requests(2)
    assert first.json["max_tokens"] == OutputTokens.default()
    assert second.json["max_tokens"] < first.json["max_tokens"]

    assert RouteFailure.classify(:credit_limited) == :usage_limit

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "the configured cap is the one the OpenRouter request carries", %{workspace: workspace} do
    parent = self()
    queue = start_supervised!({Agent, fn -> [refusal(), refusal()] end})

    assert {:ok, session} = start(workspace, queue_fun(queue, parent), backend_config: %{max_output_tokens: 9_000})

    assert {:paused, _payload} = CodingAgent.run_turn(session, "Do the work", issue(), [])

    assert [first, _second] = collect_requests(2)
    assert first.json["max_tokens"] == 9_000

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end
end
