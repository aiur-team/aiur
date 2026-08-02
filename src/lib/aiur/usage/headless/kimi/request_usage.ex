defmodule Aiur.Usage.Headless.Kimi.RequestUsage do
  @moduledoc false
  @behaviour Aiur.Usage.Headless.Adapter

  alias Aiur.Usage.Headless.OpenAICompat.RequestUsage

  @source "kimi.openai_compat.request_usage"
  @revision "kimi-request-usage-2026-08"

  @impl true
  def provider, do: :kimi
  @impl true
  def source, do: @source
  @impl true
  def source_version, do: "openai-compatible-2026-08"
  @impl true
  def relationship_revision, do: @revision
  @impl true
  def relationship_definition, do: RequestUsage.relationship_definition(provider(), @source, @revision, {:subset_of, :input})
  @impl true
  def extract(payload, _raw, context, ingested_at), do: RequestUsage.extract(__MODULE__, payload, context, ingested_at)
end
