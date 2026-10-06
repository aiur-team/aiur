defmodule Aiur.Usage.Headless.Muse.SessionUsage do
  @moduledoc """
  Maps one native Muse cumulative session counter to one absolute envelope.

  The per-turn `usage` object and `turn/completed` are deliberately not added:
  each overlaps the cumulative prompt/output/total counter. Cache and reasoning
  counts are per-turn only, so this absolute source leaves those dimensions
  unknown rather than presenting the last turn as a session total.
  """

  @behaviour Aiur.Usage.Headless.Adapter

  alias Aiur.Muse.Usage
  alias Aiur.Usage.Headless.{Adapter, Context}
  alias Aiur.UsageEnvelope

  @source "muse.msp.session_token_usage"
  @source_version "muse-msp-1.4.0"
  @revision "muse-session-usage-2026-09"
  @definition %{
    provider: :muse,
    source: @source,
    source_version: @source_version,
    revision: @revision,
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
  def provider, do: :muse
  @impl true
  def source, do: @source
  @impl true
  def source_version, do: @source_version
  @impl true
  def relationship_revision, do: @revision
  @impl true
  def relationship_definition, do: @definition

  @impl true
  def extract(%{"method" => "session/tokenUsage"} = payload, _raw, %Context{} = context, ingested_at) do
    with :ok <- revision_matches(context),
         {:ok, usage} <- Usage.token_notification(payload),
         :ok <- scope_matches(context, usage),
         {:ok, envelope} <- UsageEnvelope.new(attributes(context, usage, ingested_at)) do
      [{:ok, envelope}]
    else
      {:error, :unsupported_revision} -> [coverage(:unsupported_source_revision, :source_version)]
      {:error, :ambiguous_scope} -> [coverage(:ambiguous_measurement_semantics, :counter_scope)]
      {:error, _reason} -> [coverage(:ambiguous_measurement_semantics, :envelope)]
    end
  end

  def extract(_payload, _raw, _context, _ingested_at), do: []

  defp revision_matches(%Context{observed_source_version: version})
       when version in [nil, @source_version],
       do: :ok

  defp revision_matches(_context), do: {:error, :unsupported_revision}

  defp scope_matches(context, usage) do
    if usage.stream.kind == "session" and
         context.session_id == usage.session_id and
         context.agent_family == :muse do
      :ok
    else
      {:error, :ambiguous_scope}
    end
  end

  defp attributes(context, usage, ingested_at) do
    stream = usage.stream
    source_id = fingerprint([usage.session_id, stream.id, stream.last_id, stream.sequence])

    %{
      idempotency_key: @source <> ":" <> fingerprint([@source_version, context.run_id, usage.session_id, source_id]),
      provider: :muse,
      source: @source,
      source_version: @source_version,
      source_event_id: source_id,
      source_sequence: stream.sequence,
      occurred_at: usage.occurred_at,
      ingested_at: ingested_at,
      measurement_kind: :absolute,
      counter_scope: :session,
      counter_epoch: @source <> ":epoch:" <> fingerprint([@source_version, context.run_id, usage.session_id, stream.id]),
      update_kind: :full,
      attribution: attribution(context, usage),
      agent_family: :muse,
      backend: context.backend,
      transport: context.transport,
      auth_mode: :unknown,
      query_source: context.query_source,
      effort: context.effort,
      requested_model: context.requested_model,
      resolved_model: context.resolved_model,
      account_generation: context.account_generation,
      tokens: %{
        input: usage.cumulative.input,
        cached_input: nil,
        cache_creation_input: nil,
        output: usage.cumulative.output,
        reasoning_output: nil,
        provider_reported_total: usage.cumulative.total
      },
      relationship_revision: @revision,
      cost: nil
    }
  end

  defp attribution(context, usage) do
    %{
      run_id: context.run_id,
      tracker_identity: context.tracker_identity,
      attempt_id: context.attempt_id,
      session_id: usage.session_id,
      thread_id: context.thread_id,
      turn_id: usage.turn_id,
      request_id: context.request_id
    }
  end

  defp fingerprint(parts), do: Adapter.fingerprint(parts)
  defp coverage(class, field), do: {:coverage, Adapter.coverage(__MODULE__, class, field)}
end
