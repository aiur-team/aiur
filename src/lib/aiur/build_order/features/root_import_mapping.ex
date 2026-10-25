defmodule Aiur.BuildOrder.Features.RootImportMapping do
  @moduledoc false
  alias Aiur.BuildOrder.Metadata

  @spec slug(pos_integer()) :: String.t()
  def slug(number), do: "bo-#{number}"

  @spec clean(term()) :: String.t()
  def clean(title) when is_binary(title), do: title |> String.replace(~r/\p{Cc}/u, " ") |> String.replace(~r/\s+/u, " ") |> String.trim() |> shorten(80)
  def clean(_), do: ""

  @spec feature(map(), [map()]) :: map()
  def feature(root, members) do
    label =
      case clean(root.title) do
        "" -> "Build Order ##{root.number}"
        title -> title
      end

    lanes = members |> Enum.map(&lane(root.number, &1)) |> Enum.uniq() |> Enum.sort_by(&lane_order/1)
    lanes = if lanes == [], do: [:unassigned], else: lanes
    %{slug: slug(root.number), label: label, from: root.created_at, to: root.closed_at, hue: nil, epics: Enum.map(lanes, &epic(root.number, label, &1))}
  end

  @spec lane(pos_integer(), map()) :: String.t() | :unassigned
  def lane(root, row) do
    lane = Metadata.parse(row.labels).lane
    if lane != :unassigned and byte_size(key(root, lane)) <= 64, do: lane, else: :unassigned
  end

  @spec key(pos_integer(), term()) :: String.t()
  def key(root, :unassigned), do: "f-" <> slug(root)
  def key(root, lane), do: "f-#{slug(root)}-#{lane}"

  @spec same_repository?(map(), String.t()) :: boolean()
  def same_repository?(%{owner: owner, repository: repository}, configured), do: owner <> "/" <> repository == configured

  @spec joined_at(map(), pos_integer(), String.t()) :: DateTime.t() | :unknown
  def joined_at(root, number, repository) do
    root
    |> entries()
    |> Enum.filter(&(&1.ref.number == number and same_repository?(&1.ref, repository)))
    |> Enum.map(& &1.at)
    |> Enum.reject(&(&1 == :unknown))
    |> Enum.max(DateTime, fn -> :unknown end)
  end

  @spec entries(map()) :: [map()]
  def entries(%{sub_issues_added: entries}) when is_list(entries), do: entries
  def entries(_), do: []

  @spec skipped_lane?(pos_integer(), map()) :: boolean()
  def skipped_lane?(root, row), do: Metadata.parse(row.labels).lane != :unassigned and lane(root, row) == :unassigned

  @spec relabel(map(), String.t()) :: map()
  def relabel(epic, label) do
    # Retained epics also follow root renames after their members have left.
    case Regex.run(~r/^f-bo-[0-9]+-(.+)$/, epic.key) do
      [_, lane] -> %{epic | label: lane_label(label, lane)}
      nil -> if Regex.match?(~r/^f-bo-[0-9]+$/, epic.key), do: %{epic | label: label}, else: epic
    end
  end

  defp epic(root, label, :unassigned), do: %{key: key(root, :unassigned), label: label}
  defp epic(root, label, lane), do: %{key: key(root, lane), label: lane_label(label, lane)}

  defp lane_label(label, lane) do
    suffix = " · " <> Metadata.lane_label(lane)
    shorten(label, 80 - String.length(suffix)) <> suffix
  end

  defp shorten(text, max), do: if(String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text)
  defp lane_order(:unassigned), do: {2, 0}

  defp lane_order(lane) do
    case Enum.find_index(Metadata.lanes(), &(&1 == lane)) do
      nil -> {1, lane}
      index -> {0, index}
    end
  end
end
