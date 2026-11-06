defmodule Aiur.Lane do
  @moduledoc """
  Resolves a ticket's lanes: the technical columns — frontend, backend, docs,
  art, audio — whose work the ticket belongs to.

  A lane comes from three label prefixes (`lane:`, `area:`, `build-lane:`) and
  from the label matchers of a configured lane, so an existing install needs no
  GitHub relabel. Prefix labels come first in the fixed order `lane:`, `area:`,
  `build-lane:`, then matching configured lanes in configured order; the result
  is deduplicated in that order. Nothing here writes a GitHub label.

  Configured lanes come from `build_order.lanes` (`Aiur.Config.Schema.Lane`).
  The settings argument is the parsed struct, an `{:ok, struct}` config read, or
  that read's error; a missing or malformed value means "no configured lanes",
  never a crash. The module never reads config itself, so a caller can pass the
  settings snapshot it already holds and stay consistent with the rest of that
  render or dispatch.
  """

  alias Aiur.Config.Schema.Lane, as: LaneConfig

  @prefixes ["lane:", "area:", "build-lane:"]
  # A lane slug must survive as a config key and a map key: lowercase, no
  # spaces, bounded. Anything else in the label's suffix is not a lane.
  @lane_pattern ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  @type t :: String.t()
  @type ticket :: Aiur.Issue.t() | map() | [String.t()] | nil

  @doc """
  Lane keys for `ticket`, in resolution order: label keys first (`lane:`, then
  `area:`, then `build-lane:`), then configured lanes whose matchers hit, in
  config order. Duplicates collapse to the first occurrence.
  """
  @spec resolve(ticket(), term()) :: [t()]
  def resolve(ticket, settings) do
    labels = labels(ticket)
    Enum.uniq(label_lanes_from(labels) ++ Enum.map(matched(configured(settings), labels), & &1.key))
  end

  @doc "Lane keys named by a ticket's `lane:`, `area:` and `build-lane:` labels."
  @spec label_lanes(ticket()) :: [t()]
  def label_lanes(ticket), do: ticket |> labels() |> label_lanes_from()

  @doc "The label that puts a ticket in `lane`, or nil when the ticket is not in it."
  @spec label_match(map(), ticket()) :: String.t() | nil
  def label_match(lane, ticket), do: match_label(lane, labels(ticket))

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
  def labels(%{labels: labels}) when is_list(labels), do: normalize(labels)
  def labels(labels) when is_list(labels), do: normalize(labels)
  def labels(_ticket), do: []

  defp matched(lanes, labels), do: Enum.filter(lanes, &(not is_nil(match_label(&1, labels))))

  # A configured matcher wins over the lane's own key, because it names the exact
  # label that placed the ticket; either way config order decides between lanes.
  defp match_label(lane, labels) do
    key = lane |> lane_value(:key) |> normalize_key()

    Enum.find(matchers(lane), &(&1 in labels)) ||
      Enum.find(labels, &(not is_nil(key) and prefix_slugs(&1) == [key]))
  end

  defp matchers(lane), do: lane |> lane_value(:labels) |> LaneConfig.normalize_labels()

  defp lane_value(lane, key), do: Map.get(lane, key)

  defp normalize_key(key) when is_binary(key) do
    case String.trim(key) |> String.downcase() do
      "" -> nil
      key -> key
    end
  end

  defp normalize_key(_key), do: nil

  defp label_lanes_from(labels) do
    @prefixes
    |> Enum.flat_map(fn prefix -> Enum.flat_map(labels, &prefix_slugs(&1, prefix)) end)
    |> Enum.uniq()
  end

  defp prefix_slugs(label) when is_binary(label) do
    Enum.flat_map(@prefixes, &prefix_slugs(label, &1))
  end

  defp prefix_slugs(_label), do: []

  defp prefix_slugs(label, prefix) do
    if String.starts_with?(label, prefix) do
      slug(binary_part(label, byte_size(prefix), byte_size(label) - byte_size(prefix)))
    else
      []
    end
  end

  defp slug(suffix) do
    case String.trim(suffix) do
      slug when slug != "" -> if Regex.match?(@lane_pattern, slug), do: [slug], else: []
      _blank -> []
    end
  end

  defp normalize(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
