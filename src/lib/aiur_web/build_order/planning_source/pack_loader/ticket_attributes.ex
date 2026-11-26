defmodule AiurWeb.BuildOrder.PlanningSource.PackLoader.TicketAttributes do
  @moduledoc """
  Typed ticket attributes lifted out of a decoded planning-pack document.

  The published `build-order.v1` document reads each ticket's feature, kind,
  provenance and declared relations from these fields. They live in one module
  so the pack loader's ticket projection stays readable and a new attribute is
  added in exactly one place.
  """

  @kinds ~w(executable audit gate umbrella capstone unknown)
  @provenances ~w(planned discovered unknown)

  @spec feature(map()) :: String.t() | nil
  def feature(attributes) do
    case Map.get(attributes, "workstream") do
      feature when is_binary(feature) and feature != "" -> feature
      _missing -> nil
    end
  end

  @spec kind(map()) :: String.t() | nil
  def kind(attributes) do
    case Map.get(attributes, "kind") do
      kind when kind in @kinds -> kind
      _missing -> nil
    end
  end

  @spec provenance(map()) :: String.t() | nil
  def provenance(attributes) do
    case Map.get(attributes, "provenance") do
      provenance when provenance in @provenances -> provenance
      _missing -> nil
    end
  end

  @spec references(map(), String.t()) :: [String.t()]
  def references(attributes, key) do
    case Map.get(attributes, key) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _missing -> []
    end
  end
end
