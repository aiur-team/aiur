defmodule Aiur.Lane do
  @moduledoc """
  Resolves a ticket's lanes: the technical columns — frontend, backend, docs,
  art, audio — whose work the ticket belongs to.

  A lane comes from three label prefixes (`lane:`, `area:`, `build-lane:`) and
  from the label matchers of a configured general epic, so an existing install
  needs no GitHub relabel. Prefix labels come first in the fixed order
  `lane:`, `area:`, `build-lane:`, then matching general epics in configured
  order; the result is deduplicated in that order.

  The planned rename makes general epics "lanes" and reuses this resolver, so
  keep lane resolution here rather than inline in a consumer. This module reads
  display config from the settings it is given; it never reads config itself, so
  a caller can pass the settings snapshot it already holds and stay consistent
  with the rest of that render or dispatch.
  """

  alias Aiur.Config.Schema.GeneralEpic

  @prefixes ["lane:", "area:", "build-lane:"]
  # A lane slug must survive as a config key and a map key: lowercase, no
  # spaces, bounded. Anything else in the label's suffix is not a lane.
  @lane_pattern ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  @type t :: String.t()

  @doc """
  Lane slugs for `issue`, in resolution order.

  `settings` is a parsed settings struct (or map) carrying
  `build_order.general_epics`; `nil` or a malformed settings value means "no
  configured lanes", never a crash.
  """
  @spec resolve(Aiur.Issue.t() | map() | nil, map() | nil) :: [t()]
  def resolve(issue, settings) do
    labels = labels(issue)

    prefixed = Enum.flat_map(@prefixes, fn prefix -> Enum.flat_map(labels, &prefixed_lane(prefix, &1)) end) |> Enum.uniq()
    matched = settings |> general_epics() |> Enum.filter(&GeneralEpic.matches?(&1, labels)) |> Enum.map(& &1.key)

    Enum.uniq(prefixed ++ matched)
  end

  @doc "Normalized, deduplicated ticket labels used for lane matching."
  @spec labels(Aiur.Issue.t() | map() | nil) :: [String.t()]
  def labels(%{labels: labels}) when is_list(labels), do: normalize(labels)
  def labels(_issue), do: []

  defp normalize(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp prefixed_lane(prefix, label) do
    if String.starts_with?(label, prefix) do
      lane_slug(prefix, label)
    else
      []
    end
  end

  defp lane_slug(prefix, label) do
    suffix = binary_part(label, byte_size(prefix), byte_size(label) - byte_size(prefix))

    case String.trim(suffix) do
      slug when byte_size(slug) > 0 -> if Regex.match?(@lane_pattern, slug), do: [slug], else: []
      _blank -> []
    end
  end

  defp general_epics(%{build_order: %{general_epics: epics}}) when is_list(epics), do: epics
  defp general_epics(_settings), do: []
end
