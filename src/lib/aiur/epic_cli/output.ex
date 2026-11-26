defmodule Aiur.EpicCLI.Output do
  @moduledoc "Human rendering and refusal text for `aiur epic` record commands."

  @spec render(map()) :: String.t()
  def render(%{command: "epic list"} = result), do: render_list(result.epics)
  def render(%{command: "epic show"} = result), do: render_show(result.epic, result.features)
  def render(%{command: "epic create"} = result), do: render_write(result, "created", "created epic")
  def render(%{command: "epic edit"} = result), do: render_write(result, "updated", "updated epic")

  def render(%{command: "epic add"} = result) do
    render_membership(result, "added", "to epic")
  end

  def render(%{command: "epic remove"} = result) do
    render_membership(result, "removed", "from epic")
  end

  def render(result), do: inspect(result)

  defp render_list([]), do: "no epics"

  defp render_list(epics) do
    Enum.map_join(epics, "\n", fn epic ->
      "#{epic.slug}  #{epic.label}  #{length(epic.features)} features  #{root(epic.root)}  hue #{epic.hue}"
    end)
  end

  defp render_show(epic, features) do
    lanes =
      case epic.lanes do
        [] -> "lanes: none"
        lanes -> "lanes " <> Enum.map_join(lanes, ", ", fn lane -> "#{lane_label(lane.lane)}=#{lane.label} (#{length(lane.members)})" end)
      end

    members = Enum.map_join(epic.features, ", ", &feature_label(&1, features))

    """
    #{epic.slug}  #{epic.label}
    #{root(epic.root)}  hue #{epic.hue}#{icon(epic.icon)}  #{epic.label_source}
    features #{if members == "", do: "none", else: members}
    #{lanes}\
    """
  end

  defp render_write(%{changed: []} = result, _verb, _prefix), do: "#{result.command} #{slug(result)} unchanged"
  defp render_write(result, _verb, prefix), do: "#{prefix} #{slug(result)}"

  defp render_membership(%{changed: []} = result, _verb, _prefix), do: "#{result.command} #{slug(result)} unchanged"
  defp render_membership(result, verb, prefix), do: "#{verb} #{Enum.join(result.features, ", ")} #{prefix} #{slug(result)}"

  defp slug(%{epic: %{slug: slug}}), do: slug
  defp slug(_result), do: "?"

  defp root(nil), do: "no root"
  defp root(number), do: "root ##{number}"
  defp icon(nil), do: ""
  defp icon(name), do: "  icon #{name}"
  defp lane_label(:unassigned), do: "unassigned"
  defp lane_label(lane), do: to_string(lane)

  defp feature_label(slug, features) do
    case Map.get(features, slug) do
      %{label: label} -> "#{slug} (#{label})"
      _missing -> slug
    end
  end

  @spec error(term()) :: String.t()
  def error({:unknown_epic, slug}), do: "unknown epic #{slug}; create it with aiur epic create"
  def error({:epic_exists, slug}), do: "epic #{slug} exists with different values; use aiur epic edit"
  def error({:unknown_feature, slug}), do: "unknown feature #{slug}; create it first"
  def error({:feature_in_epic, feature, epic}), do: "feature #{feature} already belongs to epic #{epic}; remove it first"
  def error({:not_in_epic, features}), do: "not in this epic: #{Enum.join(List.wrap(features), ", ")}; re-run to read current membership"
  def error({:root_taken, root, epic}), do: "Build Order root ##{root} already belongs to epic #{epic}"
  def error(:invalid_epic_slug), do: "invalid epic slug"
  def error(:invalid_epic), do: "invalid epic fields"
  def error(:invalid_label), do: "invalid label"
  def error(:invalid_hue), do: "hue must be 0 to 359"
  def error(:invalid_icon), do: "icon must be a Heroicons v2 outline name"
  def error(:invalid_root), do: "root must be an issue number below 2147483648"
  def error(:invalid_feature_slug), do: "invalid feature slug"
  def error(:batch_too_large), do: "epic accepts at most 200 features"
  def error(%{failure: reason}), do: "epic registry unavailable (#{inspect(reason)})"

  def error(reason)
      when reason in [:epics_not_running, :version_unsupported, :state_dir_unavailable, :unsafe_path, :epics_corrupt, :epics_unavailable, :features_not_running, :features_corrupt],
      do: "epic registry unavailable (#{reason})"

  def error({:epic_journal_append_failed, reason}), do: "epic registry unavailable (journal append failed: #{inspect(reason)})"
  def error(reason), do: inspect(reason)
end
