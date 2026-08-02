defmodule Aiur.Usage.Headless.OpenAICompat.RequestUsage do
  @moduledoc false

  alias Aiur.Usage.Headless.Adapter

  @spec relationship_definition(atom(), String.t(), String.t(), :additive | {:subset_of, :input}) :: map()
  def relationship_definition(provider, source, revision, cache_relationship) do
    %{
      provider: provider,
      source: source,
      source_version: "openai-compatible-2026-08",
      revision: revision,
      provider_total_authoritative: true,
      dimensions: %{
        input: :additive,
        cached_input: cache_relationship,
        cache_creation_input: {:subset_of, :input},
        output: :additive,
        reasoning_output: {:subset_of, :output}
      }
    }
  end

  @spec extract(module(), map(), Aiur.Usage.Headless.Context.t(), DateTime.t()) :: [Adapter.result()]
  def extract(adapter, payload, context, ingested_at) when is_map(payload) do
    with usage when is_map(usage) <- payload["usage"] || payload[:usage],
         true <- measurement?(usage) do
      context = actual_attribution(context, payload)
      dimensions = dimensions(adapter.provider(), usage)

      [
        Adapter.build_envelope(
          adapter,
          context,
          source_event_id: source_event_id(adapter, payload, dimensions, context),
          ingested_at: ingested_at,
          measurement_kind: :delta,
          counter_scope: :request,
          update_kind: if(partial?(dimensions), do: :partial, else: :full),
          tokens: dimensions,
          coverage_reasons: if(partial?(dimensions), do: [:partial_update], else: [])
        )
      ]
    else
      _ -> []
    end
  end

  def extract(_adapter, _payload, _context, _ingested_at), do: []

  defp actual_attribution(context, payload) do
    resolved_model = string(payload["model"] || payload[:model]) || context.resolved_model
    selected_provider = string(payload["selected_provider"] || payload[:selected_provider] || payload["provider"] || payload[:provider])

    %{context | resolved_model: resolved_model, query_source: selected_provider || context.query_source}
  end

  defp dimensions(:deepseek, usage) do
    hit = Adapter.token(usage, ["prompt_cache_hit_tokens", :prompt_cache_hit_tokens])
    miss = Adapter.token(usage, ["prompt_cache_miss_tokens", :prompt_cache_miss_tokens])

    %{
      input: miss || Adapter.token(usage, ["prompt_tokens", :prompt_tokens, "input_tokens", :input_tokens]),
      cached_input: hit,
      cache_creation_input: nil,
      output: Adapter.token(usage, ["completion_tokens", :completion_tokens, "output_tokens", :output_tokens]),
      reasoning_output: reasoning_tokens(usage),
      provider_reported_total: Adapter.token(usage, ["total_tokens", :total_tokens])
    }
  end

  defp dimensions(_provider, usage) do
    %{
      input: Adapter.token(usage, ["prompt_tokens", :prompt_tokens, "input_tokens", :input_tokens]),
      cached_input: cached_tokens(usage),
      cache_creation_input: cache_write_tokens(usage),
      output: Adapter.token(usage, ["completion_tokens", :completion_tokens, "output_tokens", :output_tokens]),
      reasoning_output: reasoning_tokens(usage),
      provider_reported_total: Adapter.token(usage, ["total_tokens", :total_tokens])
    }
  end

  defp cached_tokens(usage) do
    Adapter.token(usage, ["cached_tokens", :cached_tokens, "cache_read_input_tokens", :cache_read_input_tokens]) ||
      nested_token(usage, ["prompt_tokens_details", :prompt_tokens_details], ["cached_tokens", :cached_tokens]) ||
      nested_token(usage, ["input_tokens_details", :input_tokens_details], ["cached_tokens", :cached_tokens])
  end

  defp cache_write_tokens(usage) do
    Adapter.token(usage, ["cache_write_tokens", :cache_write_tokens]) ||
      nested_token(usage, ["prompt_tokens_details", :prompt_tokens_details], ["cache_write_tokens", :cache_write_tokens])
  end

  defp reasoning_tokens(usage) do
    Adapter.token(usage, ["reasoning_tokens", :reasoning_tokens]) ||
      nested_token(usage, ["completion_tokens_details", :completion_tokens_details], ["reasoning_tokens", :reasoning_tokens]) ||
      nested_token(usage, ["output_tokens_details", :output_tokens_details], ["reasoning_tokens", :reasoning_tokens])
  end

  defp nested_token(usage, parent_keys, token_keys) do
    Enum.find_value(parent_keys, fn parent ->
      case Map.get(usage, parent) do
        details when is_map(details) -> Adapter.token(details, token_keys)
        _ -> nil
      end
    end)
  end

  defp measurement?(usage) do
    Enum.any?(["prompt_tokens", "input_tokens", "completion_tokens", "output_tokens", "total_tokens"], &is_integer(usage[&1]))
  end

  defp partial?(dimensions), do: is_nil(dimensions.input) or is_nil(dimensions.output)

  defp source_event_id(adapter, payload, dimensions, context) do
    adapter.source() <>
      ":" <>
      Adapter.fingerprint([
        payload["request_id"] || payload[:request_id] || context.request_id || context.turn_id,
        context.source_sequence,
        context.resolved_model,
        dimensions.input,
        dimensions.output,
        dimensions.provider_reported_total
      ])
  end

  defp string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp string(_), do: nil
end
