defmodule Aiur.Usage.PriceTable.Data do
  @moduledoc """
  Reviewed, immutable standard API-equivalent token prices.

  Prices use major USD units per one million tokens. Runtime code never fetches
  these sources; a source update adds a new effective-dated revision.
  """

  @catalog_revision "api-equivalent-standard-global-2026-07-15"
  @effective_date ~D[2026-07-15]
  @reviewed_at ~D[2026-07-15]
  @token_unit 1_000_000
  @pricing_scope "standard_global_direct_non_batch"

  @openai_source "https://developers.openai.com/api/docs/pricing"
  @openai_revision "openai-standard-global-2026-07-15"
  @openai_relationship "codex-app-server-2026-07"
  @openai_models [
    {"gpt-5.6-sol", %{input: "5.00", cached_input: "0.50", cache_creation_input: "6.25", output: "30.00"}},
    {"gpt-5.6-terra", %{input: "2.50", cached_input: "0.25", cache_creation_input: "3.125", output: "15.00"}},
    {"gpt-5.6-luna", %{input: "1.00", cached_input: "0.10", cache_creation_input: "1.25", output: "6.00"}}
  ]

  @anthropic_source "https://platform.claude.com/docs/en/about-claude/pricing"
  @anthropic_revision "anthropic-standard-global-2026-07-15"
  @anthropic_relationship "claude-remote-control-2026-07"
  @anthropic_models [
    {"claude-opus-4-8", %{input: "5.00", cached_input: "0.50", cache_creation_input: "6.25", output: "25.00"}},
    {"claude-sonnet-4-6", %{input: "3.00", cached_input: "0.30", cache_creation_input: "3.75", output: "15.00"}},
    {"claude-haiku-4-5", %{input: "1.00", cached_input: "0.10", cache_creation_input: "1.25", output: "5.00"}}
  ]

  @spec catalog_revision() :: String.t()
  def catalog_revision, do: @catalog_revision

  @spec entries() :: [map()]
  def entries do
    model_entries(:codex, @openai_models, @openai_relationship, @openai_revision, @openai_source) ++
      model_entries(
        :claude,
        @anthropic_models,
        @anthropic_relationship,
        @anthropic_revision,
        @anthropic_source
      )
  end

  defp model_entries(provider, models, relationship, revision, source) do
    Enum.flat_map(models, fn {model, rates} ->
      rates
      |> Map.put(:reasoning_output, rates.output)
      |> Enum.map(fn {dimension, price} ->
        %{
          provider: provider,
          resolved_model: model,
          token_dimension: dimension,
          relationship_revision: relationship,
          currency: "USD",
          price: price,
          token_unit: @token_unit,
          effective_date: @effective_date,
          price_revision: revision,
          source_url: source,
          source_reviewed_at: @reviewed_at,
          pricing_scope: @pricing_scope
        }
      end)
    end)
  end
end
