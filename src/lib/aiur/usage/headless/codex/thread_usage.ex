defmodule Aiur.Usage.Headless.Codex.ThreadUsage do
  @moduledoc """
  Maps the Codex cumulative thread token counter into an absolute usage envelope.

  The source is `info.total_token_usage`: a monotonic, thread-scoped snapshot.
  It is emitted as `measurement_kind: :absolute` / `counter_scope: :thread` so
  the DASH-009 single writer alone decides a durable additive delta. This
  adapter never derives a cross-message delta and never treats the overlapping
  absolute and per-turn delta streams as independently additive.
  """

  @behaviour Aiur.Usage.Headless.Adapter

  alias Aiur.Usage.Headless.Adapter
  alias Aiur.Usage.Headless.Codex.Tokens

  @source "codex.app_server.thread_token_usage"
  @source_version "codex-app-server-2026-07"
  @relationship_revision "codex-thread-usage-2026-07"
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
    case Tokens.cumulative(payload) do
      nil ->
        []

      usage ->
        dimensions = Tokens.dimensions(usage)
        [Adapter.build_envelope(__MODULE__, context, source_facts(dimensions, context, ingested_at))]
    end
  end

  def extract(_payload, _raw, _context, _ingested_at), do: []

  defp source_facts(dimensions, context, ingested_at) do
    [
      source_event_id: source_event_id(dimensions, context),
      ingested_at: ingested_at,
      measurement_kind: :absolute,
      counter_scope: :thread,
      update_kind: :full,
      tokens: dimensions
    ]
  end

  defp source_event_id(dimensions, context) do
    @source <>
      ":" <>
      Adapter.fingerprint([
        context.thread_id || context.session_id,
        dimensions.input,
        dimensions.output,
        dimensions.provider_reported_total
      ])
  end
end
