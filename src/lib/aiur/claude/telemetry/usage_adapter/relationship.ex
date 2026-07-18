defmodule Aiur.Claude.Telemetry.UsageAdapter.Relationship do
  @moduledoc false

  alias Aiur.Claude.Telemetry.Contract
  alias Aiur.UsageEnvelope
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @revision "claude-remote-control-2026-07"
  @definition %{
    provider: :claude,
    source: Contract.source(),
    source_version: Contract.source_version(),
    revision: @revision,
    provider_total_authoritative: false,
    dimensions: %{
      input: :additive,
      cached_input: :additive,
      cache_creation_input: :additive,
      output: :additive,
      reasoning_output: {:subset_of, :output}
    }
  }

  @spec revision() :: String.t()
  def revision, do: @revision

  @spec definition() :: map()
  def definition, do: @definition

  @spec catalog() :: RelationshipRegistry.catalog()
  def catalog do
    {:ok, catalog} = RelationshipRegistry.new([@definition])
    catalog
  end

  @spec supported?(RelationshipRegistry.catalog(), UsageEnvelope.t()) :: :ok | {:error, term()}
  def supported?(catalog, envelope) do
    case RelationshipRegistry.resolve(catalog, envelope) do
      {:ok, @definition} -> :ok
      {:ok, _different} -> {:error, :invalid_relationship_catalog}
      {:error, reason} -> {:error, reason}
    end
  end
end
