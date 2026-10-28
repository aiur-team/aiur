defmodule AiurWeb.Streamdeck.Render.Settings do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.SettingsMenu
  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.Streamdeck.Render.{Style, Svg}

  @spec frame(map(), map(), map(), String.t() | nil) :: map()
  def frame(menu, settings, devices, toast) do
    choices =
      if is_nil(menu.section) do
        Enum.map(SettingsMenu.sections(), fn {section, label} -> %{label: label, detail: SettingsMenu.summary(section, settings, devices)} end)
      else
        Enum.map(SettingsMenu.choices(menu.section, settings, devices), &Map.put(&1, :detail, if(&1.value == settings[menu.section], do: "Selected", else: "Choose")))
      end

    page = if is_nil(menu.section), do: 0, else: div(menu.cursor, 8)

    keys =
      Enum.map(0..7, fn physical ->
        index = page * 8 + rem(physical, 4) * 2 + div(physical, 4)

        case Enum.at(choices, index) do
          nil -> nil
          item -> key(item, index == menu.cursor)
        end
      end)

    title = if is_nil(menu.section), do: "Settings", else: Enum.find_value(SettingsMenu.sections(), fn {key, name} -> if key == menu.section, do: name end)
    selected = Enum.at(choices, menu.cursor)
    label = if selected, do: selected.label, else: "No devices"
    status = toast || if(is_nil(menu.section), do: "Choose section", else: "#{menu.cursor + 1}/#{length(choices)} · #{label}")

    regions = [
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
    ]

    %{keys: keys, strip: Render.strip(regions)}
  end
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
