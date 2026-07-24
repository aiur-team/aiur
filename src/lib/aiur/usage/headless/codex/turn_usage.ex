defmodule Aiur.Usage.Headless.Codex.TurnUsage do
  @moduledoc """
  Maps the Codex per-turn token delta into a turn-scoped delta usage envelope.

  The source is the turn-completion `usage` map (or the equivalent
  `info.last_token_usage`): the increment that produced the latest cumulative
  thread snapshot. It is emitted as `measurement_kind: :delta` /
  `counter_scope: :turn`, distinct from the absolute thread stream, so the two
  overlapping streams are never summed as if independent. This adapter performs
  no cross-message subtraction; it only preserves the delta the source reports.
  """

  @behaviour Aiur.Usage.Headless.Adapter

  alias Aiur.Usage.Headless.Adapter
  alias Aiur.Usage.Headless.Codex.Tokens

  @source "codex.app_server.turn_token_usage"
  @source_version "codex-app-server-2026-07"
  @relationship_revision "codex-turn-usage-2026-07"
  @definition %{
    provider: :codex,
    source: @source,
    source_version: @source_version,
    revision: @relationship_revision,
    provider_total_authoritative: true,
    dimensions: %{
      input: :additive,
      cached_input: {:subset_of, :input},
      cache_creation_input: {:subset_of, :input},
      output: :additive,
      reasoning_output: {:subset_of, :output}
    }
  }

  @impl true
  def provider, do: :codex

  @impl true
  def source, do: @source

  @impl true
  def source_version, do: @source_version

  @impl true
  def relationship_revision, do: @relationship_revision

  @impl true
  def relationship_definition, do: @definition

  @impl true
  def extract(payload, _raw, context, ingested_at) when is_map(payload) do
    case Tokens.turn_completed(payload) || Tokens.last(payload) do
      nil ->
        []

      usage ->
        dimensions = Tokens.dimensions(usage)
        [Adapter.build_envelope(__MODULE__, context, source_facts(dimensions, Tokens.context_tier(usage), context, ingested_at))]
    end
  end

  def extract(_payload, _raw, _context, _ingested_at), do: []

  defp source_facts(dimensions, context_tier, context, ingested_at) do
    [
      source_event_id: source_event_id(dimensions, context),
      ingested_at: ingested_at,
      measurement_kind: :delta,
      counter_scope: :turn,
      update_kind: :full,
      tokens: dimensions,
      context_tier: context_tier
    ]
  end

  defp source_event_id(dimensions, context) do
    @source <>
      ":" <>
      Adapter.fingerprint([
        context.turn_id || context.session_id,
        context.source_sequence,
        dimensions.input,
        dimensions.output,
        dimensions.provider_reported_total
      ])
  end
end
