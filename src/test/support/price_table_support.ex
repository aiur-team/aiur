defmodule Aiur.TestSupport.PriceTable do
  @moduledoc false

  def query(%Date{} = date), do: query(%{pricing_effective_date: date})

  def query(overrides) when is_map(overrides) do
    Map.merge(
      %{
        provider: :codex,
        resolved_model: "gpt-5.6-terra",
        token_dimension: :input,
        relationship_revision: "codex-app-server-2026-07",
        currency: "USD",
        context_tier: :short_context,
        cache_write_duration: :not_applicable,
        pricing_effective_date: ~D[2026-07-15]
      },
      overrides
    )
  end

  def query(provider, model, dimension, context_tier, cache_write_duration) do
    query(%{
      provider: provider,
      resolved_model: model,
      token_dimension: dimension,
      relationship_revision: relationship_revision(provider),
      context_tier: context_tier,
      cache_write_duration: cache_write_duration
    })
  end

  def deepseek_query(model, dimension, effective_date, pricing_window) do
    query(:deepseek, model, dimension, :not_applicable, :not_applicable)
    |> Map.put(:pricing_effective_date, effective_date)
    |> then(&if(is_nil(pricing_window), do: &1, else: Map.put(&1, :pricing_window, pricing_window)))
  end

  def entry(overrides \\ %{}) do
    Map.merge(
      %{
        provider: :codex,
        resolved_model: "gpt-5.6-terra",
        token_dimension: :input,
        relationship_revision: "codex-app-server-2026-07",
        currency: "USD",
        context_tier: :short_context,
        cache_write_duration: :not_applicable,
        window: :flat,
        price: "2.50",
        token_unit: 1_000_000,
        effective_date: ~D[2026-07-15],
        price_revision: "price-1",
        source_url: "https://developers.openai.com/api/docs/pricing",
        source_reviewed_at: ~D[2026-07-15],
        pricing_scope: "standard_global_direct_non_batch"
      },
      overrides
    )
  end

  def relationship_revision(:codex), do: "codex-app-server-2026-07"
  def relationship_revision(:claude), do: "claude-remote-control-2026-07"
  def relationship_revision(:kimi), do: "kimi-request-usage-2026-08"
  def relationship_revision(:deepseek), do: "deepseek-request-usage-2026-08"
  def relationship_revision(:openrouter), do: "openrouter-request-usage-2026-08"

  def price_revision(:codex), do: "openai-standard-global-2026-07-15"
  def price_revision(:claude), do: "anthropic-standard-global-2026-07-15"

  def source_url(:codex), do: "https://developers.openai.com/api/docs/pricing"
  def source_url(:claude), do: "https://platform.claude.com/docs/en/about-claude/pricing"
end
