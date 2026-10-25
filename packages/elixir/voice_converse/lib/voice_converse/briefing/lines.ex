defmodule VoiceConverse.Briefing.Lines do
  @moduledoc false
  # One line per briefing field. `render/2` joins them with age text; `diff/2` compares them
  # without it, so the passing of time never looks like a change.

  @fields [
    summary: "Summary",
    current_task: "Doing now",
    next_steps: "Next",
    waiting_on: "Waiting on",
    questions: "Questions for you"
  ]

  @type line :: %{
          key: term(),
          label: String.t(),
          text: String.t(),
          empty?: boolean(),
          observed_at: DateTime.t() | nil,
          max_age_s: pos_integer() | nil
        }

  @doc "Canonical heading label for each `field/1` key, in render order."
  def fields, do: @fields

  @spec build(VoiceConverse.Briefing.t()) :: [line()]
  def build(briefing) do
    field_lines = for {key, label} <- @fields, do: field_line(key, label, Map.fetch!(briefing, key))
    extra_lines = for {title, texts} <- extra_by_title(briefing.extra), do: line({:extra, title}, title, texts)

    field_lines ++
      extra_lines ++
      list_line(:links, "Links", Enum.map(briefing.links, &link/1)) ++
      list_line(:gaps, "Gaps", briefing.gaps)
  end

  @spec to_text([line()], DateTime.t()) :: String.t()
  def to_text(lines, now), do: Enum.map_join(lines, "\n", &(&1.text <> age_suffix(&1, now)))

  defp field_line(key, label, nil), do: line(key, label, "not reported")
  defp field_line(key, label, %{value: nil}), do: line(key, label, "not reported")

  defp field_line(key, label, %{value: value} = field) do
    %{line(key, label, value) | observed_at: field[:observed_at], max_age_s: field[:max_age_s]}
  end

  # Extras sharing a title become one line, so each diff key is unique and stable.
  defp extra_by_title(extra) do
    titles = extra |> Enum.map(& &1.title) |> Enum.uniq()
    groups = Enum.group_by(extra, & &1.title, & &1.text)
    for title <- titles, do: {title, groups[title]}
  end

  defp list_line(_key, _label, []), do: []
  defp list_line(key, label, items), do: [line(key, label, items)]

  defp line(key, label, value) do
    %{
      key: key,
      label: label,
      text: "#{label}: #{format(value)}",
      empty?: value in ["", []],
      observed_at: nil,
      max_age_s: nil
    }
  end

  defp format(value) when value in ["", []], do: "none"
  defp format(items) when is_list(items), do: Enum.join(items, "; ")
  defp format(text) when is_binary(text), do: text

  defp link(%{label: label, url: url}), do: "#{label} <#{url}>"

  defp age_suffix(%{observed_at: %DateTime{} = at, max_age_s: max}, now) when is_integer(max) do
    age = DateTime.diff(now, at, :second)
    if age > max, do: " (as of #{ago(age)})", else: ""
  end

  defp age_suffix(_line, _now), do: ""

  defp ago(s) when s < 60, do: "#{s} s ago"
  defp ago(s) when s < 3_600, do: "#{div(s, 60)} min ago"
  defp ago(s), do: "#{div(s, 3_600)} h ago"
end
