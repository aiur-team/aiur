defmodule Aiur.Orchestrator.TokenAccounting.PayloadsTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.TokenAccounting.Payloads

  test "extracts cumulative usage from nested Codex payloads" do
    usage = %{"inputTokens" => "11", "outputTokens" => 4, "totalTokens" => 15}

    update = %{
      payload: %{
        params: %{msg: %{payload: %{info: %{total_token_usage: usage}}}}
      }
    }

    assert Payloads.extract_token_usage(update) == usage
  end

  test "falls back to turn-completed usage only for recognized methods" do
    usage = %{"prompt_tokens" => "7", "completion_tokens" => 3, "total_tokens" => 10}
    payload = %{"method" => "turn/completed", "params" => %{"usage" => usage}}

    assert Payloads.extract_token_usage(%{"payload" => payload}) == usage

    assert Payloads.extract_token_usage(%{
             "payload" => put_in(payload, ["method"], "turn/started")
           }) == %{}
  end

  test "normalizes supported token aliases and rejects negative values" do
    usage = %{"promptTokens" => " 7 ", completion: 3, total: "10"}

    assert Payloads.get_token_usage(usage, :input) == 7
    assert Payloads.get_token_usage(usage, :output) == 3
    assert Payloads.get_token_usage(usage, :total) == 10
    assert Payloads.get_token_usage(%{input_tokens: -1}, :input) == nil
    assert Payloads.get_token_usage(%{output_tokens: "-1"}, :output) == nil
  end

  test "finds recognizable rate limits recursively and rejects incomplete maps" do
    rate_limits = %{"limit_name" => "requests", "credits" => %{"remaining" => 2}}

    update = %{
      payload: [
        %{"unrelated" => true},
        %{"wrapper" => %{"rate_limits" => rate_limits}}
      ]
    }

    assert Payloads.extract_rate_limits(update) == rate_limits

    assert Payloads.extract_rate_limits(%{
             rate_limits: %{primary: %{remaining: 1}}
           }) == nil
  end
end
