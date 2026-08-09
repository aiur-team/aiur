defmodule Aiur.Usage.Headless.Catalog do
  @moduledoc """
  The registry of pinned headless usage adapters and their relationship catalog.

  Each adapter contributes exactly one immutable relationship definition keyed by
  `(provider, source, source_version, revision)`. Registering a newer revision
  never changes how a retained envelope is interpreted.
  """

  alias Aiur.CodingAgent
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @spec adapters() :: [module()]
  def adapters do
    CodingAgent.provider_descriptors()
    |> Enum.flat_map(&(get_in(&1, [:usage, :adapters]) || []))
  end

  @spec adapters_for(atom()) :: [module()]
  def adapters_for(provider) when is_atom(provider) do
    CodingAgent.provider_descriptor(provider)
    |> then(&get_in(&1 || %{}, [:usage, :adapters]))
    |> Kernel.||([])
  end

  def adapters_for(_provider), do: []

  @spec relationship_catalog() :: RelationshipRegistry.catalog()
  def relationship_catalog do
    {:ok, catalog} = RelationshipRegistry.new(Enum.map(adapters(), & &1.relationship_definition()))
    catalog
  end
end
