defmodule Aiur.Usage.PriceTable.Data do
  @moduledoc """
  Reviewed, immutable standard API-equivalent token prices.

  Prices use major USD units per one million tokens. Runtime code never fetches
  these sources; a source update adds a new effective-dated revision instead of
  overwriting, so historical spend keeps the rate that was actually in effect
  and a stale rate is detectable from the entry's `effective_date`,
  `source_reviewed_at`, and `price_revision` rather than failing silently.
  """

  @catalog_revision "multi-provider-standard-global-2026-08-16"
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

  # Effective date shared by every OpenAI-compatible model that has not been
  # repriced since it was first reviewed. A repriced model carries its own
  # dated revisions below; each revision's `source_reviewed_at` is its
  # effective date.
  @provider_effective_date ~D[2026-08-01]

  # One model maps to one or more `{effective_date, rates, tag}` revisions.
  # Effective dates are inclusive and the next revision in a series is the
  # exclusive bound (see `Aiur.Usage.PriceTable`), so a repricing is an
  # addition that leaves historical spend correctly valued. `tag` decorates the
  # price revision so a deliberately-windowed rate (e.g. `:peak`) is
  # self-describing in cost surfaces.
  @openai_compat_models %{
    kimi: [
      {"kimi-k2.7-code", [{@provider_effective_date, %{input: "0.95", cached_input: "0.19", output: "4.00"}, nil}]},
      {"kimi-k2.7-code-highspeed", [{@provider_effective_date, %{input: "0.95", cached_input: "0.19", output: "4.00"}, nil}]}
    ],
    deepseek: [
      {"deepseek-v4-flash",
       [
         {@provider_effective_date, %{input: "0.14", cached_input: "0.0028", output: "0.28"}, nil},
         # DeepSeek repriced to peak/off-peak billing effective 16:00 UTC
         # 2026-08-16 (peak = 2x off-peak; verified against the live pricing
         # docs). The price table is date-granular with one rate per dimension,
         # so the conservative PEAK rate is priced here: it can never hide
         # overspend (the retained $0.28 output rate under-reported peak spend
         # by up to 79%). The off-peak schedule ($0.22 input / $0.007 cached /
         # $0.66 output) is time-of-day dependent and tracked by #1456.
         {~D[2026-08-16], %{input: "0.44", cached_input: "0.014", output: "1.32"}, :peak}
       ]}
    ],
    openrouter: [
      {"deepseek/deepseek-v4-flash",
       [
         {@provider_effective_date, %{input: "0.14", cached_input: "0.0028", output: "0.28"}, nil},
         # OpenRouter's DeepSeek listing is flat (third-party hosts; it does
         # not follow DeepSeek's peak schedule), verified against the OpenRouter
         # model overview 2026-08-16.
         {~D[2026-08-16], %{input: "0.06426", cached_input: "0.012852", output: "0.12852"}, nil}
       ]},
      {"moonshotai/kimi-k2.7-code", [{@provider_effective_date, %{input: "0.95", cached_input: "0.19", output: "4.00"}, nil}]},
      {"anthropic/claude-sonnet-5", [{@provider_effective_date, %{input: "2.00", cached_input: "0.20", output: "10.00"}, nil}]},
      {"anthropic/claude-opus-5", [{@provider_effective_date, %{input: "5.00", cached_input: "0.50", output: "25.00"}, nil}]}
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
        {model, revisions} <- models,
        {effective_date, rates, tag} <- revisions,
        {dimension, price} <- openai_compat_rates(rates) do
      openai_compat_entry(provider, model, dimension, price, effective_date, tag)
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

  defp openai_compat_entry(provider, model, dimension, price, effective_date, tag) do
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
      effective_date: effective_date,
      price_revision: openai_compat_price_revision(provider, effective_date, tag),
      source_url: openai_compat_source(provider),
      source_reviewed_at: effective_date,
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

  defp openai_compat_price_revision(provider, effective_date, tag) do
    base = "#{provider}-standard-global-#{Date.to_iso8601(effective_date)}"
    if tag, do: base <> "-#{tag}", else: base
  end

  defp openai_compat_source(:kimi), do: "https://platform.kimi.ai/docs/pricing/chat-k27-code"
  defp openai_compat_source(:deepseek), do: "https://api-docs.deepseek.com/quick_start/pricing"
  defp openai_compat_source(:openrouter), do: "https://openrouter.ai/docs/overview/models"
end
