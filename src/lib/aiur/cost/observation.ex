defmodule Aiur.Cost.Observation do
  @moduledoc """
  Extracts a provider-neutral **absolute** token snapshot from one normalized
  backend message, for per-ticket cost accounting.

  Token counts come from the raw message's cumulative usage total (see
  `docs/token_accounting.md` — `thread/tokenUsage/updated.tokenUsage.total` and
  the `info.total_token_usage` fallback), reusing the same absolute-path parser
  the orchestrator already trusts (`TokenAccounting.Payloads`). Pricing metadata
  (provider, resolved model, relationship revision, pricing date, context tier)
  comes from the DASH-008 usage envelope the emitter already built for the same
  message. Messages carrying no absolute usage total are skipped.
  """

  alias Aiur.Orchestrator.TokenAccounting.Payloads
  alias Aiur.UsageEnvelope

  @type t :: %{
          thread_id: String.t(),
          input_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          context_window: non_neg_integer() | nil,
          meta: map()
        }

  @cached_keys ["cached_input_tokens", :cached_input_tokens, "cachedInputTokens", :cachedInputTokens, "cached_tokens", :cached_tokens]

  @context_window_paths [
    ["params", "tokenUsage", "model_context_window"],
    [:params, :tokenUsage, :model_context_window],
    ["tokenUsage", "model_context_window"],
    [:tokenUsage, :model_context_window],
    ["params", "msg", "payload", "info", "model_context_window"],
    [:params, :msg, :payload, :info, :model_context_window],
    ["params", "msg", "info", "model_context_window"],
    [:params, :msg, :info, :model_context_window]
  ]

  @thread_id_paths [
    ["params", "thread_id"],
    [:params, :thread_id],
    ["thread_id"],
    [:thread_id],
    ["params", "threadId"],
    [:params, :threadId]
  ]

  @doc """
  Builds an absolute observation from a normalized message and the usage
  envelopes the emitter produced for it. Returns `:skip` when the message
  carries no cumulative token total.
  """
  @spec from_message(String.t(), map(), [UsageEnvelope.t()]) :: {:ok, t()} | :skip
  def from_message(backend, message, envelopes)
      when is_binary(backend) and is_map(message) and is_list(envelopes) do
    usage = Payloads.extract_token_usage(message)

    input = Payloads.get_token_usage(usage, :input)
    output = Payloads.get_token_usage(usage, :output)
    total = Payloads.get_token_usage(usage, :total)

    if is_nil(input) and is_nil(output) and is_nil(total) do
      :skip
    else
      envelope = first_envelope(envelopes)

      {:ok,
       %{
         thread_id: thread_id(message, envelope),
         input_tokens: input || 0,
         cached_input_tokens: cached_tokens(usage),
         output_tokens: output || 0,
         total_tokens: total || (input || 0) + (output || 0),
         context_window: context_window(message),
         meta: meta(backend, envelope)
       }}
    end
  end

  def from_message(_backend, _message, _envelopes), do: :skip

  defp first_envelope(envelopes) do
    Enum.find(envelopes, &match?(%UsageEnvelope{}, &1))
  end

  defp cached_tokens(usage) when is_map(usage) do
    Enum.find_value(@cached_keys, 0, fn key ->
      case Map.get(usage, key) do
        value when is_integer(value) and value >= 0 -> value
        _ -> nil
      end
    end)
  end

  defp cached_tokens(_usage), do: 0

  defp context_window(message) do
    case first_path(roots(message), @context_window_paths) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp thread_id(message, envelope) do
    envelope_thread_id(envelope) || to_thread_id(first_path(roots(message), @thread_id_paths))
  end

  # Codex nests the usage payload under `message.payload.params...`, but internal
  # messages can carry `params` at the top level. Search both so the paths below
  # (rooted at `params`/`tokenUsage`) resolve in either shape — the same tolerance
  # `TokenAccounting.Payloads` applies for the token counts.
  defp roots(message) do
    Enum.filter([message, Map.get(message, :payload), Map.get(message, "payload")], &is_map/1)
  end

  defp envelope_thread_id(%UsageEnvelope{attribution: %{thread_id: id}}) when is_binary(id) and id != "", do: id
  defp envelope_thread_id(_envelope), do: nil

  defp to_thread_id(id) when is_binary(id) and id != "", do: id
  defp to_thread_id(id) when is_integer(id), do: Integer.to_string(id)
  defp to_thread_id(_id), do: "unknown"

  defp meta(backend, %UsageEnvelope{} = envelope) do
    %{
      provider: envelope.provider || provider_for(backend),
      resolved_model: envelope.resolved_model,
      relationship_revision: envelope.relationship_revision,
      pricing_effective_date: envelope.pricing_effective_date,
      context_tier: envelope.context_tier
    }
  end

  defp meta(backend, _envelope) do
    %{
      provider: provider_for(backend),
      resolved_model: nil,
      relationship_revision: nil,
      pricing_effective_date: nil,
      context_tier: nil
    }
  end

  defp provider_for(backend) do
    case String.downcase(backend) do
      "claude" -> :claude
      _ -> :codex
    end
  end

  defp first_path(roots, paths) when is_list(roots) do
    Enum.find_value(paths, fn path ->
      Enum.find_value(roots, fn root -> path_get(root, path) end)
    end)
  end

  defp path_get(map, path) when is_map(map) do
    Enum.reduce_while(path, map, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp path_get(_map, _path), do: nil
end
