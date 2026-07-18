defmodule Aiur.Usage.Headless.Catalog do
  @moduledoc """
  The registry of pinned headless usage adapters and their relationship catalog.

  Each adapter contributes exactly one immutable relationship definition keyed by
  `(provider, source, source_version, revision)`. Registering a newer revision
  never changes how a retained envelope is interpreted.
  """

  alias Aiur.Usage.Headless.Claude
  alias Aiur.Usage.Headless.Codex
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @adapters [Codex.ThreadUsage, Codex.TurnUsage, Claude.RequestUsage]

  @spec adapters() :: [module()]
  def adapters, do: @adapters

  @spec adapters_for(:codex | :claude) :: [module()]
  def adapters_for(:codex), do: [Codex.ThreadUsage, Codex.TurnUsage]
  def adapters_for(:claude), do: [Claude.RequestUsage]
  def adapters_for(_provider), do: []

  @spec relationship_catalog() :: RelationshipRegistry.catalog()
  def relationship_catalog do
    {:ok, catalog} = RelationshipRegistry.new(Enum.map(@adapters, & &1.relationship_definition()))
    catalog
  end
end
