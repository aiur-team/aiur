defmodule Aiur.Lane do
  @moduledoc """
  Resolves a ticket's lanes from its labels and the configured lanes.

  A lane is a technical column such as frontend, backend, docs or art. A ticket
  lands in a lane when it carries a `lane:`, `area:` or `build-lane:` label with
  that lane's key, or when one of the lane's configured label matchers is on the
  ticket. `area:` and `build-lane:` are read as lane labels so an existing
  repository needs no relabel; nothing here writes a GitHub label.

  Configured lanes come from `build_order.lanes` (`Aiur.Config.Schema.Lane`).
  The functions accept a settings map, the `{:ok, settings}` read result, or a
  settings read error, so a caller that could not read config resolves no
  configured lanes instead of crashing.
  """

  alias Aiur.Config.Schema.Lane, as: Config

  @label_prefixes ~w(lane area build-lane)

  @type ticket :: map() | [String.t()] | nil

  @doc """
  Lane keys for a ticket, in resolution order: label keys first (`lane:`, then
  `area:`, then `build-lane:`), then configured lanes whose matchers hit, in
  config order. Duplicates collapse to the first occurrence.
  """
  @spec resolve(ticket(), term()) :: [String.t()]
  def resolve(ticket, settings) do
    labels = labels(ticket)
    Enum.uniq(label_lanes(labels) ++ Enum.map(matched(labels, settings), & &1.key))
  end

  @doc "Lane keys named by a ticket's `lane:`, `area:` and `build-lane:` labels."
  @spec label_lanes(ticket()) :: [String.t()]
  def label_lanes(ticket), do: ticket |> labels() |> Enum.flat_map(&slug/1) |> Enum.uniq()

  @doc "The label that puts a ticket in `lane`, or nil when the ticket is not in it."
  @spec label_match(map(), ticket()) :: String.t() | nil
  def label_match(lane, ticket) do
    labels = labels(ticket)
    key = Map.get(lane, :key)

    Enum.find(Config.normalize_labels(Map.get(lane, :labels)), &(&1 in labels)) ||
      Enum.find(labels, &(slug(&1) == [key]))
  end

  @doc "Whether a ticket belongs to the lane by a matcher or by a lane label."
  @spec matches?(map(), ticket()) :: boolean()
  def matches?(lane, ticket), do: not is_nil(label_match(lane, ticket))

  @doc "Configured lanes in config order, or none when the settings read failed."
  @spec configured(term()) :: [map()]
  def configured({:ok, settings}), do: configured(settings)
  def configured(%{build_order: %{lanes: lanes}}) when is_list(lanes), do: lanes
  def configured(_settings), do: []

  @doc "A ticket's labels, trimmed, downcased and de-duplicated."
  @spec labels(ticket()) :: [String.t()]
  def labels(%{labels: labels}), do: labels(labels)
  def labels(labels) when is_list(labels), do: labels |> Enum.filter(&is_binary/1) |> Config.normalize_labels()
  def labels(_ticket), do: []

  defp matched(labels, settings), do: Enum.filter(configured(settings), &matches?(&1, labels))

  defp slug(label) do
    case String.split(label, ":", parts: 2) do
      [prefix, value] when prefix in @label_prefixes -> blank_or(value)
      _other -> []
    end
  end

  defp blank_or(value) do
    case String.trim(value) do
      "" -> []
      slug -> [slug]
    end
  end
end
