defmodule AiurWeb.Streamdeck.Render.Settings do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.SettingsMenu
  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.Streamdeck.Render.{Style, Svg}

  @spec frame(map(), map(), map(), String.t() | nil) :: map()
  def frame(menu, settings, devices, toast) do
    choices = choices(menu, settings, devices)
    %{keys: keys(menu, choices), strip: strip(menu, choices, toast)}
  end

  defp choices(%{section: nil}, settings, devices) do
    Enum.map(SettingsMenu.sections(), fn {section, label} -> %{label: label, detail: SettingsMenu.summary(section, settings, devices)} end)
  end

  defp choices(menu, settings, devices) do
    Enum.map(SettingsMenu.choices(menu.section, settings, devices), &Map.put(&1, :detail, if(&1.value == settings[menu.section], do: "Selected", else: "Choose")))
  end

  defp keys(menu, choices) do
    page = if is_nil(menu.section), do: 0, else: div(menu.cursor, 8)

    Enum.map(0..7, fn physical ->
      index = page * 8 + rem(physical, 4) * 2 + div(physical, 4)
      key(Enum.at(choices, index), index == menu.cursor)
    end)
  end

  defp strip(menu, choices, toast) do
    title = title(menu.section)
    status = toast || status(menu, choices)

    Render.strip([
      %{
        x: 0,
        width: 800,
        label: "#{title} · #{status}",
        parts: [
          %{kind: :text_line, text: title, y: 24, size: 14},
          %{kind: :text_line, text: status, y: 50, size: 12},
          %{kind: :text_line, text: "Dial 1: scroll / press select · Hold dial 4: back", y: 82, size: 11}
        ]
      }
    ])
  end

  defp title(nil), do: "Settings"
  defp title(section), do: SettingsMenu.sections() |> List.keyfind(section, 0) |> elem(1)
  defp status(%{section: nil}, _choices), do: "Choose section"
  defp status(menu, choices), do: "#{menu.cursor + 1}/#{length(choices)} · #{choice_label(Enum.at(choices, menu.cursor))}"
  defp choice_label(nil), do: "No devices"
  defp choice_label(choice), do: choice.label
  defp key(nil, _focused), do: nil

  defp key(item, focused) do
    style = Style.state("paused")

    content = [
      Svg.element("rect", width: 120, height: 120, rx: 15, fill: hd(style.glow)),
      Svg.element("rect", x: 3, y: 3, width: 114, height: 114, rx: 12, fill: hd(style.face)),
      if(focused, do: Svg.text("●", 101, 22, 12, fill: style.accent), else: []),
      item.label |> Svg.wrap(Svg.budget(120, 9, 14), 3) |> Enum.with_index() |> Enum.map(fn {line, row} -> Svg.text(line, 9, 43 + row * 16, 14) end),
      Svg.text(item.detail |> String.slice(0, 17), 9, 106, 10, fill: style.accent)
    ]

    Svg.image(content, 120, 120, "#{item.label} · #{item.detail}")
  end
end
