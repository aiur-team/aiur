defmodule AiurWeb.OperatorControlCenter.UnitsRow do
  @moduledoc """
  Pure, provenance-rich projection for one current-run Units snapshot.

  Membership defines which rows exist. Every cross-source lookup uses the
  repository-qualified `TrackerIdentity` key, never a display identifier.
  """

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.UnitsRow.{Projection, Sources}

  @version 1

  @spec version() :: pos_integer()
  def version, do: @version

  @spec snapshot(map()) :: map()
  def snapshot(inputs) when is_map(inputs) do
    sources = Sources.normalize(inputs)

    %{
      version: @version,
      generation: Sources.generation(sources),
      health: Sources.health(sources),
      freshness: Sources.freshness(sources),
      truncated?: Sources.truncated?(sources),
      rows: Projection.rows(sources.membership, Sources.indexes(sources), sources)
    }
  end

  def snapshot(_inputs), do: snapshot(%{})

  @spec lookup([map()] | map(), TrackerIdentity.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(%{rows: rows}, identity), do: lookup(rows, identity)

  def lookup(rows, %TrackerIdentity{} = identity) when is_list(rows) do
    case Enum.find(rows, &(Sources.key(Map.get(&1, :identity)) == Sources.key(identity))) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  def lookup(_rows, _identity), do: {:error, :not_found}
end
