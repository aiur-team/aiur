defmodule Aiur.Usage.PriceTable.Data do
  @moduledoc """
  Reviewed, immutable standard API-equivalent token prices.

  Prices use major USD units per one million tokens. Runtime code never fetches
  these sources; a source update adds a new effective-dated revision.
  """

  @catalog_revision "multi-provider-standard-global-2026-08-01"
  @effective_date ~D[2026-07-15]
  @reviewed_at ~D[2026-07-15]
  @token_unit 1_000_000
  @pricing_scope "standard_global_direct_non_batch"
  @dimensions [:input, :cached_input, :cache_creation_input, :output, :reasoning_output]

  @openai_source "https://developers.openai.com/api/docs/pricing"
  @openai_revision "openai-standard-global-2026-07-15"
  @openai_relationship "codex-app-server-2026-07"
  @openai_models [
    {"gpt-5.6-sol",
     [
       short_context: %{input: "5.00", cached_input: "0.50", cache_creation_input: "6.25", output: "30.00"},
       long_context: %{input: "10.00", cached_input: "1.00", cache_creation_input: "12.50", output: "45.00"}
     ]},
    {"gpt-5.6-terra",
     [
       short_context: %{input: "2.50", cached_input: "0.25", cache_creation_input: "3.125", output: "15.00"},
       long_context: %{input: "5.00", cached_input: "0.50", cache_creation_input: "6.25", output: "22.50"}
     ]},
    {"gpt-5.6-luna",
     [
       short_context: %{input: "1.00", cached_input: "0.10", cache_creation_input: "1.25", output: "6.00"},
       long_context: %{input: "2.00", cached_input: "0.20", cache_creation_input: "2.50", output: "9.00"}
     ]}
  ]

  @anthropic_source "https://platform.claude.com/docs/en/about-claude/pricing"
  @anthropic_revision "anthropic-standard-global-2026-07-15"
  @anthropic_relationship "claude-remote-control-2026-07"
  @anthropic_models [
    {"claude-opus-4-8", %{input: "5.00", cached_input: "0.50", five_minutes: "6.25", one_hour: "10.00", output: "25.00"}},
    {"claude-sonnet-4-6", %{input: "3.00", cached_input: "0.30", five_minutes: "3.75", one_hour: "6.00", output: "15.00"}},
    {"claude-haiku-4-5", %{input: "1.00", cached_input: "0.10", five_minutes: "1.25", one_hour: "2.00", output: "5.00"}}
  ]

  @provider_effective_date ~D[2026-08-01]
  @provider_reviewed_at ~D[2026-08-01]
  @openai_compat_models %{
    kimi: [
      {"kimi-k2.7-code", %{input: "0.95", cached_input: "0.19", output: "4.00"}},
      {"kimi-k2.7-code-highspeed", %{input: "0.95", cached_input: "0.19", output: "4.00"}}
    ],
    deepseek: [
      {"deepseek-v4-flash", %{input: "0.14", cached_input: "0.0028", output: "0.28"}}
    ],
    openrouter: [
      {"deepseek/deepseek-v4-flash", %{input: "0.14", cached_input: "0.0028", output: "0.28"}},
      {"moonshotai/kimi-k2.7-code", %{input: "0.95", cached_input: "0.19", output: "4.00"}},
      {"anthropic/claude-sonnet-5", %{input: "2.00", cached_input: "0.20", output: "10.00"}},
      {"anthropic/claude-opus-5", %{input: "5.00", cached_input: "0.50", output: "25.00"}}
    ]
  }

  @spec catalog_revision() :: String.t()
  def catalog_revision, do: @catalog_revision

  @spec entries() :: [map()]
  def entries, do: openai_entries() ++ anthropic_entries() ++ openai_compat_entries()

  defp openai_entries do
    for {model, contexts} <- @openai_models,
        {context_tier, rates} <- contexts,
        dimension <- @dimensions do
      entry(:codex, model, dimension, rate(rates, dimension), %{
        context_tier: context_tier,
        cache_write_duration: :not_applicable
      })
    end
  end

  defp anthropic_entries do
    for {model, rates} <- @anthropic_models,
        {dimension, duration, price} <- anthropic_rates(rates) do
      entry(:claude, model, dimension, price, %{
        context_tier: :not_applicable,
        cache_write_duration: duration
      })
    end
  end

  defp openai_compat_entries do
    for {provider, models} <- @openai_compat_models,
        {model, rates} <- models,
        {dimension, price} <- openai_compat_rates(rates) do
      openai_compat_entry(provider, model, dimension, price)
    end
  end

  defp openai_compat_rates(rates) do
    [
      input: rates.input,
      cached_input: rates.cached_input,
      output: rates.output,
      reasoning_output: rates.output
    ]
  end

  defp openai_compat_entry(provider, model, dimension, price) do
    %{
      provider: provider,
      resolved_model: model,
      token_dimension: dimension,
      relationship_revision: openai_compat_relationship(provider),
      currency: "USD",
      context_tier: :not_applicable,
      cache_write_duration: :not_applicable,
      price: price,
      token_unit: @token_unit,
      effective_date: @provider_effective_date,
      price_revision: openai_compat_price_revision(provider),
      source_url: openai_compat_source(provider),
      source_reviewed_at: @provider_reviewed_at,
      pricing_scope: @pricing_scope
    }
  end

  defp anthropic_rates(rates) do
    [
      {:input, :not_applicable, rates.input},
      {:cached_input, :not_applicable, rates.cached_input},
      {:cache_creation_input, :five_minutes, rates.five_minutes},
      {:cache_creation_input, :one_hour, rates.one_hour},
      {:output, :not_applicable, rates.output},
      {:reasoning_output, :not_applicable, rates.output}
    ]
  end

  defp entry(provider, model, dimension, price, dimensions) do
    Map.merge(
      %{
        provider: provider,
        resolved_model: model,
        token_dimension: dimension,
        relationship_revision: relationship_revision(provider),
        currency: "USD",
        price: price,
        token_unit: @token_unit,
        effective_date: @effective_date,
        price_revision: price_revision(provider),
        source_url: source(provider),
        source_reviewed_at: @reviewed_at,
        pricing_scope: @pricing_scope
      },
      dimensions
    )
  end

  defp rate(rates, :reasoning_output), do: rates.output
  defp rate(rates, dimension), do: Map.fetch!(rates, dimension)

  defp relationship_revision(:codex), do: @openai_relationship
  defp relationship_revision(:claude), do: @anthropic_relationship

  defp price_revision(:codex), do: @openai_revision
  defp price_revision(:claude), do: @anthropic_revision

  defp source(:codex), do: @openai_source
  defp source(:claude), do: @anthropic_source

  defp openai_compat_relationship(:kimi), do: "kimi-request-usage-2026-08"
  defp openai_compat_relationship(:deepseek), do: "deepseek-request-usage-2026-08"
  defp openai_compat_relationship(:openrouter), do: "openrouter-request-usage-2026-08"

  defp openai_compat_price_revision(provider), do: "#{provider}-standard-global-2026-08-01"

  defp openai_compat_source(:kimi), do: "https://platform.kimi.ai/docs/pricing/chat-k27-code"
  defp openai_compat_source(:deepseek), do: "https://api-docs.deepseek.com/quick_start/pricing"
  defp openai_compat_source(:openrouter), do: "https://openrouter.ai/docs/overview/models"
end
