defmodule Aiur.Usage.Headless.Fake.RequestUsage do
  @moduledoc false

  @behaviour Aiur.Usage.Headless.Adapter

  alias Aiur.Usage.Headless.Adapter

  @source "fake.app_server.request_usage"
  @source_version "fake-app-server-1"
  @relationship_revision "fake-app-server-1"

  @definition %{
    provider: :fake,
    source: @source,
    source_version: @source_version,
    revision: @relationship_revision,
    provider_total_authoritative: false,
    dimensions: %{
      input: :additive,
      cached_input: :unknown,
      cache_creation_input: :unknown,
      output: :unknown,
      reasoning_output: :unknown
    }
  }

  @impl true
  def provider, do: :fake

  @impl true
  def source, do: @source

  @impl true
  def source_version, do: @source_version

  @impl true
  def relationship_revision, do: @relationship_revision

  @impl true
  def relationship_definition, do: @definition

  @impl true
  def extract(%{"fake_input_tokens" => tokens, "request_id" => request_id}, _raw, context, ingested_at)
      when is_integer(tokens) and tokens >= 0 and is_binary(request_id) do
    [
      Adapter.build_envelope(
        __MODULE__,
        context,
        source_event_id: request_id,
        ingested_at: ingested_at,
        measurement_kind: :delta,
        counter_scope: :request,
        update_kind: :full,
        tokens: %{
          input: tokens,
          cached_input: nil,
          cache_creation_input: nil,
          output: nil,
          reasoning_output: nil,
          provider_reported_total: nil
        }
      )
    ]
  end

  def extract(_payload, _raw, _context, _ingested_at), do: []
end
