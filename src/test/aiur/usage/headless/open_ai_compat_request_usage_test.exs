defmodule Aiur.Usage.Headless.OpenAICompatRequestUsageTest do
  use ExUnit.Case, async: true

  alias Aiur.ProviderAccountGeneration.Snapshot
  alias Aiur.Usage.Headless.Context
  alias Aiur.Usage.Headless.{DeepSeek, Kimi, OpenRouter}
  alias Aiur.UsageAggregate.Key

  @now ~U[2026-08-01 12:00:00Z]

  test "DeepSeek preserves cache-hit and miss tokens as disjoint billable inputs" do
    payload = %{
      "request_id" => "req-deepseek",
      "model" => "deepseek-v4-flash",
      "usage" => %{
        "prompt_cache_miss_tokens" => 90,
        "prompt_cache_hit_tokens" => 10,
        "completion_tokens" => 20,
        "total_tokens" => 120
      }
    }

    assert [{:ok, envelope}] = DeepSeek.RequestUsage.extract(payload, nil, context(:deepseek), @now)
    assert envelope.backend == :openai_compat
    assert envelope.transport == :openai_compat
    assert envelope.resolved_model == "deepseek-v4-flash"
    assert envelope.tokens.input == 90
    assert envelope.tokens.cached_input == 10
    assert envelope.tokens.output == 20

    cell = {{Key.dims(envelope), {:token, :input}}, 90}
    assert {:ok, ^cell} = cell |> Key.encode_cell() |> Key.decode_cell()
  end

  test "OpenRouter records the selected upstream without overloading query source" do
    payload = %{
      "request_id" => "req-openrouter",
      "model" => "deepseek/deepseek-v4-flash",
      "provider" => "OpenRouter",
      "upstream_provider" => "DeepSeek",
      "usage" => %{
        "prompt_tokens" => 100,
        "completion_tokens" => 25,
        "total_tokens" => 125,
        "prompt_tokens_details" => %{"cached_tokens" => 80}
      }
    }

    context = %{context(:openrouter) | query_source: "repl_main_thread"}

    assert [{:ok, envelope}] = OpenRouter.RequestUsage.extract(payload, nil, context, @now)
    assert envelope.resolved_model == "deepseek/deepseek-v4-flash"
    assert envelope.upstream_provider == "DeepSeek"
    assert envelope.query_source == "repl_main_thread"
    assert envelope.tokens.cached_input == 80
  end

  test "OpenRouter keeps exact safe upstream identities distinct in synthesized event identity" do
    payload = %{
      "model" => "router/auto",
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
    }

    assert [{:ok, upper}] =
             OpenRouter.RequestUsage.extract(Map.put(payload, "upstream_provider", "DeepSeek"), nil, context(:openrouter), @now)

    assert [{:ok, lower}] =
             OpenRouter.RequestUsage.extract(Map.put(payload, "upstream_provider", "deepseek"), nil, context(:openrouter), @now)

    assert upper.upstream_provider == "DeepSeek"
    assert lower.upstream_provider == "deepseek"
    refute upper.source_event_id == lower.source_event_id
  end

  test "OpenRouter discards invalid upstream identities without dropping usage" do
    invalid_values = ["", "Deep Seek", "provider-secret", String.duplicate("a", 257)]

    for upstream <- invalid_values do
      payload = %{
        "request_id" => "req-invalid-upstream",
        "upstream_provider" => upstream,
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
      }

      assert [{:ok, envelope}] = OpenRouter.RequestUsage.extract(payload, nil, context(:openrouter), @now)
      assert envelope.upstream_provider == nil
      assert envelope.tokens.provider_reported_total == 5
    end
  end

  test "direct OpenAI-compatible providers never record an upstream" do
    payload = %{
      "request_id" => "req-direct",
      "model" => "deepseek-chat",
      "upstream_provider" => "DeepSeek",
      "provider" => "DeepSeek",
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
    }

    assert [{:ok, envelope}] = DeepSeek.RequestUsage.extract(payload, nil, context(:deepseek), @now)
    assert envelope.upstream_provider == nil
    assert envelope.query_source == nil
  end

  test "Kimi does not invent cache usage when the response omits it" do
    payload = %{
      "request_id" => "req-kimi",
      "model" => "kimi-k2.7-code",
      "usage" => %{"prompt_tokens" => 50, "completion_tokens" => 10, "total_tokens" => 60}
    }

    assert [{:ok, envelope}] = Kimi.RequestUsage.extract(payload, nil, context(:kimi), @now)
    assert envelope.tokens.cached_input == nil
    assert envelope.tokens.input == 50
  end

  test "atom-keyed usage is recognized and measured" do
    payload = %{
      request_id: "req-atom-usage",
      model: "kimi-k2.7-code",
      usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
    }

    assert [{:ok, envelope}] = Kimi.RequestUsage.extract(payload, nil, context(:kimi), @now)
    assert envelope.tokens.input == 12
    assert envelope.tokens.output == 3
    assert envelope.tokens.provider_reported_total == 15
  end

  defp context(provider) do
    %Context{
      run_id: "run-1",
      agent_family: provider,
      backend: :openai_compat,
      transport: :openai_compat,
      auth_mode: :api_key,
      requested_model: "requested-model",
      resolved_model: "requested-model",
      account_generation: Context.project_generation(Snapshot.unavailable(provider, :openai_compat), provider, :openai_compat),
      source_sequence: 1
    }
  end
end
