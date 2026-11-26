defmodule Aiur.Usage.Headless.Catalog do
  @moduledoc """
  The registry of pinned headless usage adapters and their relationship catalog.

  Each adapter contributes exactly one immutable relationship definition keyed by
  `(provider, source, source_version, revision)`. Registering a newer revision
  never changes how a retained envelope is interpreted.
  """

  alias Aiur.UsageEnvelope.RelationshipRegistry

  @adapters_by_provider %{
    claude: [Aiur.Usage.Headless.Claude.RequestUsage],
    codex: [Aiur.Usage.Headless.Codex.ThreadUsage, Aiur.Usage.Headless.Codex.TurnUsage],
    deepseek: [Aiur.Usage.Headless.DeepSeek.RequestUsage],
    fake: [Aiur.Usage.Headless.Fake.RequestUsage],
    kimi: [Aiur.Usage.Headless.Kimi.RequestUsage],
    muse: [Aiur.Usage.Headless.Muse.SessionUsage],
    openrouter: [Aiur.Usage.Headless.OpenRouter.RequestUsage]
  }

  @spec adapters() :: [module()]
  def adapters, do: Enum.flat_map(@adapters_by_provider, fn {_provider, adapters} -> adapters end)

  @spec adapters_for(atom()) :: [module()]
  def adapters_for(provider) when is_atom(provider), do: Map.get(@adapters_by_provider, provider, [])

  def adapters_for(_provider), do: []

  @spec relationship_catalog() :: RelationshipRegistry.catalog()
  def relationship_catalog do
    {:ok, catalog} = RelationshipRegistry.new(Enum.map(adapters(), & &1.relationship_definition()))
    catalog
  end
end
