defmodule AiurWeb.Streamdeck.Render.ViewStrip do
  @moduledoc false
  alias AiurWeb.Streamdeck.Render.{Style, Svg, Views}
  import Svg, only: [field: 2, field: 3]

  @spec compose(map(), map()) :: [map()]
  def compose(model, context) do
    parts = parts(to_string(field(model, :surface)), context)
    label = Enum.map_join(parts, " · ", &(field(&1, :text) || field(&1, :label, "")))
    active = field(context, :active, %{}) || %{}
    pager = "CONTROLLING ##{field(active, :identifier, "")}"

    [
      %{x: 0, width: 600, label: label, parts: parts},
      %{
        x: 600,
        width: 200,
        label: pager,
        parts: [
          %{kind: :pager, title: "CONTROLLING", label: "##{field(active, :identifier, "")}"}
        ]
      }
    ]
  end

  defp parts("cmd", context) do
    agent = field(context, :active, %{}) || %{}
    state = Style.state(field(agent, :bucket, :queued))
    percent = field(agent, :progress_percent)

    [
      %{
        kind: :text_line,
        text: "##{field(agent, :identifier)} #{field(agent, :title)}",
        y: 20,
        size: 14
      },
      %{
        kind: :text_line,
        text: "#{field(agent, :vendor)} · #{state.label}",
        colour: state.accent,
        y: 40,
        size: 11
      },
      %{
        kind: :meter_row,
        label: state.label,
        percent: percent,
        freshness: field(agent, :progress_freshness, :unknown),
        suffix: "",
        y: 65
      }
    ]
  end

  defp parts("logs", context) do
    entries = field(context, :strip_entries, [])

    entries =
      if entries == [], do: [%{shape: :message, text: "No recent transcript."}], else: entries

    entries
    |> Enum.flat_map(&entry_lines/1)
    |> Enum.take(6)
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      Map.merge(line, %{kind: :text_line, y: 14 + index * 16, size: 10})
    end)
  end

  defp parts("settings", _context) do
    Views.settings_text()
    |> Enum.flat_map(&Svg.wrap(&1, 91, 3))
    |> Enum.take(6)
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      %{kind: :text_line, text: line, y: 14 + index * 16, size: 10}
    end)
  end

  defp parts("commands", context) do
    panel = field(context, :commands_panel, %{})

    lines =
      if field(panel, :view) == "history",
        do: ["COMMANDS", history_status(panel), field(panel, :note, "")],
        else: [
          field(panel, :status),
          field(panel, :question),
          field(panel, :reading),
          field(panel, :note)
        ]

    note = field(panel, :note)
    lines = Enum.reject(lines, &(&1 in [nil, false, "", note])) |> Enum.flat_map(&Svg.wrap(&1, 91, 3))
    lines = if is_binary(note) and note != "", do: Enum.take(lines, 5) ++ Svg.wrap(note, 91, 1), else: Enum.take(lines, 6)
    lines |> Enum.with_index() |> Enum.map(fn {line, index} -> %{kind: :text_line, text: line, y: 14 + index * 16, size: 10} end)
  end

  defp parts(_surface, _context), do: []

  defp history_status(panel),
    do:
      if(field(panel, :unavailable?, false),
        do: "UNAVAILABLE",
        else: "#{field(panel, :active, 0)} OPEN"
      )

  defp entry_lines(%{shape: :evhdr} = entry),
    do: lines("#{entry.direction} #{entry.text} #{entry.time}", :evhdr, entry.colour)

  defp entry_lines(%{shape: :diff} = entry),
    do:
      lines(
        "#{entry.file} +#{entry.additions} -#{entry.deletions} #{entry.line}",
        :diff,
        "#f1f3f6"
      )

  defp entry_lines(%{shape: :diff_line} = entry), do: lines(entry.line, :diff, "#f1f3f6")

  defp entry_lines(entry),
    do: lines("#{field(entry, :glyph, "")} #{field(entry, :text, "")}", :message, "#f1f3f6")

  defp lines(text, shape, colour),
    do: Enum.map(Svg.wrap(text, 91, 3), &%{text: &1, shape: shape, colour: colour})
end
