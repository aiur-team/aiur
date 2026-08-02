defmodule Aiur.Usage.Headless.Claude.RequestUsage do
  @moduledoc """
  Maps a Claude headless turn-completion into a delta usage envelope.

  The source is the `turn/completed` `usage` map plus the structured
  provider-estimated `cost_usd`. Base input, cache-read input, and cache-creation
  input are three additive input dimensions, per Anthropic's published pricing
  contract, pinned to this exact source revision. Cost is recovered as an exact
  decimal from the raw provider JSON before any float conversion; the
  already-decoded float is only ever a lossy fallback recorded as bounded
  coverage. This adapter derives no cross-message delta.
  """

  @behaviour Aiur.Usage.Headless.Adapter

  alias Aiur.Usage.Headless.Adapter

  @source "claude.app_server.turn_completion"
  @source_version "claude-app-server-2026-07"
  @relationship_revision "claude-request-usage-2026-07"
  @cost_source @source <> ".cost_usd"
  # The installed app-server surface reports usage at turn completion; the true
  # counter scope is therefore the turn, preserved rather than relabelled.
  @counter_scope :turn
  @cost_paths ["cost_usd", ["params", "cost_usd"]]
  @definition %{
    provider: :claude,
    source: @source,
    source_version: @source_version,
    revision: @relationship_revision,
    provider_total_authoritative: false,
    dimensions: %{
      input: :additive,
      cached_input: :additive,
      cache_creation_input: :additive,
      output: :additive,
      reasoning_output: {:subset_of, :output}
    }
  }

  @impl true
  def provider, do: :claude

  @impl true
  def source, do: @source

  @impl true
  def source_version, do: @source_version

  @impl true
  def relationship_revision, do: @relationship_revision

  @impl true
  def relationship_definition, do: @definition

  @impl true
  def extract(payload, raw, context, ingested_at) when is_map(payload) do
    case usage_map(payload) do
      nil ->
        cost_only(payload, raw, context, ingested_at)

      usage ->
        [envelope(usage, payload, raw, context, ingested_at)]
    end
  end

  def extract(_payload, _raw, _context, _ingested_at), do: []

  # A completion may carry cost without a usage map; still emit the exact cost.
  defp cost_only(payload, raw, context, ingested_at) do
    case cost(payload, raw) do
      {cost, _reasons} when not is_nil(cost) -> [envelope(%{}, payload, raw, context, ingested_at)]
      _absent -> []
    end
  end

  defp envelope(usage, payload, raw, context, ingested_at) do
    {dimensions, cache_write_duration} = dimensions(usage)
    {cost, cost_reasons} = cost(payload, raw)
    partial? = is_nil(dimensions.cached_input) or is_nil(dimensions.cache_creation_input)

    Adapter.build_envelope(
      __MODULE__,
      context,
      source_event_id: source_event_id(dimensions, cost, context),
      ingested_at: ingested_at,
      measurement_kind: :delta,
      counter_scope: @counter_scope,
      update_kind: if(partial?, do: :partial, else: :full),
      tokens: dimensions,
      cache_write_duration: cache_write_duration,
      cost: cost,
      coverage_reasons: coverage_reasons(partial?, cost_reasons)
    )
  end

  defp dimensions(usage) do
    {cache_creation_input, cache_write_duration} = cache_creation(usage)

    {%{
       input: Adapter.token(usage, ["input_tokens", :input_tokens, "prompt_tokens", :prompt_tokens]),
       cached_input: Adapter.token(usage, ["cache_read_input_tokens", :cache_read_input_tokens, "cache_read_tokens", :cache_read_tokens]),
       cache_creation_input: cache_creation_input,
       output: Adapter.token(usage, ["output_tokens", :output_tokens, "completion_tokens", :completion_tokens]),
       reasoning_output: nil,
       provider_reported_total: Adapter.token(usage, ["total_tokens", :total_tokens, "total", :total])
     }, cache_write_duration}
  end

  defp cache_creation(usage) do
    case Map.get(usage, "cache_creation") || Map.get(usage, :cache_creation) do
      breakdown when is_map(breakdown) ->
        five_minutes = Adapter.token(breakdown, ["ephemeral_5m_input_tokens", :ephemeral_5m_input_tokens])
        one_hour = Adapter.token(breakdown, ["ephemeral_1h_input_tokens", :ephemeral_1h_input_tokens])
        {sum_cache_creation(five_minutes, one_hour), cache_write_duration(five_minutes, one_hour)}

      _absent ->
        tokens = Adapter.token(usage, ["cache_creation_input_tokens", :cache_creation_input_tokens, "cache_creation_tokens", :cache_creation_tokens])
        {tokens, if(is_integer(tokens) and tokens > 0, do: :five_minutes, else: :not_applicable)}
    end
  end

  defp sum_cache_creation(nil, nil), do: nil
  defp sum_cache_creation(five_minutes, one_hour), do: (five_minutes || 0) + (one_hour || 0)

  defp cache_write_duration(five_minutes, one_hour) when is_integer(five_minutes) and five_minutes > 0 and one_hour in [nil, 0],
    do: :five_minutes

  defp cache_write_duration(five_minutes, one_hour) when is_integer(one_hour) and one_hour > 0 and five_minutes in [nil, 0],
    do: :one_hour

  defp cache_write_duration(five_minutes, one_hour) when five_minutes in [nil, 0] and one_hour in [nil, 0],
    do: :not_applicable

  # One envelope cannot partition cache writes across both TTL prices. Leave
  # the duration unknown so the adapter emits bounded coverage rather than
  # selecting either price.
  defp cache_write_duration(_five_minutes, _one_hour), do: nil

  defp usage_map(payload) do
    candidate = Map.get(payload, "usage") || Map.get(payload, :usage) || nested_usage(payload)
    if is_map(candidate) and measurement?(candidate), do: candidate
  end

  defp nested_usage(payload) do
    params = Map.get(payload, "params") || Map.get(payload, :params) || %{}
    Map.get(params, "usage") || Map.get(params, :usage)
  end

  defp measurement?(usage) do
    {dimensions, _cache_write_duration} = dimensions(usage)
    Enum.any?(dimensions, fn {_dimension, value} -> is_integer(value) end)
  end

  defp cost(payload, raw) do
    decoded = Map.get(payload, "cost_usd") || Map.get(payload, :cost_usd) || nested_cost(payload)

    case Adapter.exact_cost(raw, decoded, @cost_paths) do
      {:ok, amount} -> {money(amount), []}
      # A lossy float with no raw JSON cannot be made exact; drop it rather than
      # introduce a float conversion the contract forbids.
      :imprecise -> {nil, []}
      :absent -> {nil, []}
    end
  end

  defp nested_cost(payload) do
    params = Map.get(payload, "params") || Map.get(payload, :params) || %{}
    Map.get(params, "cost_usd") || Map.get(params, :cost_usd)
  end

  defp money(amount) do
    %{
      amount: amount,
      currency: "USD",
      unit: :major,
      source_representation: :major,
      measurement_kind: :delta,
      counter_scope: @counter_scope,
      source: @cost_source,
      source_version: @source_version,
      coverage: :full
    }
  end

  defp coverage_reasons(partial?, cost_reasons) do
    if partial?, do: [:partial_update | cost_reasons], else: cost_reasons
  end

  defp source_event_id(dimensions, cost, context) do
    @source <>
      ":" <>
      Adapter.fingerprint([
        context.turn_id || context.request_id || context.session_id,
        context.source_sequence,
        dimensions.input,
        dimensions.output,
        cost_fingerprint(cost)
      ])
  end

  defp cost_fingerprint(%{amount: %Decimal{} = amount}), do: Decimal.to_string(amount, :normal)
  defp cost_fingerprint(_cost), do: nil
end
