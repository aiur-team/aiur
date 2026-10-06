defmodule Aiur.Usage.Headless.Gemini.TurnUsage do
  @moduledoc "Version-pinned per-turn token counts from Gemini CLI ACP prompt results."
  @behaviour Aiur.Usage.Headless.Adapter

  alias Aiur.Usage.Headless.{Adapter, Context}
  alias Aiur.UsageEnvelope

  @source "gemini.acp.prompt_quota"
  @source_version "gemini-acp-0.61.0"
  @revision "gemini-prompt-quota-2026-09"
  @definition %{
    provider: :gemini,
    source: @source,
    source_version: @source_version,
    revision: @revision,
    provider_total_authoritative: false,
    dimensions: %{
      input: :additive,
      cached_input: {:subset_of, :input},
      cache_creation_input: {:subset_of, :input},
      output: :additive,
      reasoning_output: {:subset_of, :output}
    }
  }

  @impl true
  def provider, do: :gemini
  @impl true
  def source, do: @source
  @impl true
  def source_version, do: @source_version
  @impl true
  def relationship_revision, do: @revision
  @impl true
  def relationship_definition, do: @definition

  @impl true
  def extract(%{"method" => "session/prompt", "id" => id, "result" => result, "aiurCliVersion" => version, "aiurSessionId" => session_id}, _raw, %Context{agent_family: :gemini} = context, ingested_at)
      when is_integer(id) and is_map(result) and is_binary(session_id) do
    if version == "0.61.0" do
      quota = get_in(result, ["_meta", "quota", "token_count"])
      usage_from_quota(quota, context, session_id, id, ingested_at)
    else
      [{:coverage, Adapter.coverage(__MODULE__, :unsupported_source_revision, :source_version)}]
    end
  end

  def extract(_payload, _raw, _context, _ingested_at), do: []

  defp usage_from_quota(%{"input_tokens" => input, "output_tokens" => output}, context, session_id, id, ingested_at)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0,
       do: envelope(context, session_id, id, input, output, ingested_at)

  defp usage_from_quota(_, _, _, _, _),
    do: [{:coverage, Adapter.coverage(__MODULE__, :missing_usage_measurement, :tokens)}]

  defp envelope(context, session_id, id, input, output, ingested_at) do
    event_id = Adapter.fingerprint([session_id, id])

    attributes = %{
      idempotency_key: @source <> ":" <> Adapter.fingerprint([@source_version, context.run_id, context.attempt_id, session_id, id]),
      provider: :gemini,
      source: @source,
      source_version: @source_version,
      source_event_id: event_id,
      source_sequence: context.source_sequence,
      occurred_at: ingested_at,
      ingested_at: ingested_at,
      measurement_kind: :delta,
      counter_scope: :turn,
      counter_epoch: @source <> ":epoch:" <> Adapter.fingerprint([context.run_id, session_id]),
      update_kind: :full,
      attribution: %{
        run_id: context.run_id,
        tracker_identity: context.tracker_identity,
        attempt_id: context.attempt_id,
        session_id: session_id,
        thread_id: session_id,
        turn_id: to_string(id),
        request_id: context.request_id
      },
      agent_family: :gemini,
      backend: context.backend,
      transport: context.transport,
      auth_mode: :unknown,
      query_source: context.query_source,
      effort: nil,
      requested_model: context.requested_model,
      resolved_model: context.resolved_model,
      account_generation: context.account_generation,
      tokens: %{
        input: input,
        cached_input: nil,
        cache_creation_input: nil,
        output: output,
        reasoning_output: nil,
        provider_reported_total: nil
      },
      relationship_revision: @revision,
      cost: nil
    }

    case UsageEnvelope.new(attributes) do
      {:ok, envelope} -> [{:ok, envelope}]
      {:error, _} -> [{:coverage, Adapter.coverage(__MODULE__, :ambiguous_measurement_semantics, :envelope)}]
    end
  end
end
