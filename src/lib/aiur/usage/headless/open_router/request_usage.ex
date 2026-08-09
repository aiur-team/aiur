defmodule Aiur.Usage.Headless.OpenRouter.RequestUsage do
  @moduledoc false
  @behaviour Aiur.Usage.Headless.Adapter

  alias Aiur.Usage.Headless.OpenAICompat.RequestUsage

  @source "openrouter.openai_compat.request_usage"
  @revision "openrouter-request-usage-2026-08"

  @impl true
  def provider, do: :openrouter
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
