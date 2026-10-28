defmodule AiurWeb.Streamdeck.Render.Settings do
  @moduledoc "Settings expressed as shared Card faces and strip parts."
  alias AiurWeb.Streamdeck.Deck.{Nav, Settings, SettingsMenu}

  @spec compose(map()) :: {[map() | nil], [map()]}
  def compose(context) when is_map(context) do
    menu = context.menu
    choices = items(context)
    {faces(menu, choices), regions(context, choices)}
  end

  def compose(_context), do: compose(%{menu: %Nav{}.settings, values: Settings.defaults(), devices: nil, status: :unavailable})

  defp faces(menu, choices) do
    page = if is_nil(menu.section), do: 0, else: div(menu.cursor, 8)

    Enum.map(0..7, fn physical ->
      index = page * 8 + rem(physical, 4) * 2 + div(physical, 4)
      face(Enum.at(choices, index), index == menu.cursor)
    end)
  end

  defp regions(context, choices) do
    menu = context.menu
    title = if is_nil(menu.section), do: "Settings", else: SettingsMenu.sections() |> List.keyfind(menu.section, 0) |> elem(1)
    status = reading(context, choices)

    [
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
  end

  defp items(%{menu: %{section: nil}} = context) do
    Enum.map(SettingsMenu.sections(), fn {section, label} ->
      detail = if context.status == :ok, do: SettingsMenu.summary(section, context.values, context.devices), else: "Unavailable"
      %{label: label, detail: detail, disabled: context.status != :ok}
    end)
  end

  defp items(context) do
    snapshot = %{settings: context.values, devices: context.devices, status: context.status}
    Enum.map(SettingsMenu.options(context.menu.section, snapshot), &Map.put(&1, :detail, if(&1.value == context.values[context.menu.section], do: "Selected", else: "Choose")))
  end

  defp reading(%{menu: %{notice: "Not saved"}}, _choices), do: "Not saved"
  defp reading(%{status: status}, _choices) when status != :ok, do: "Unavailable"

  defp reading(context, choices) do
    if SettingsMenu.available?(context.menu.section, context.devices), do: context.menu.notice || status(context, choices), else: "Unavailable"
  end

  defp status(%{menu: %{section: nil}}, _choices), do: "Choose section"

  defp status(context, []) do
    if context.status != :ok or is_nil(context.devices), do: "Unavailable", else: "No devices"
  end

  defp status(context, choices), do: "#{context.menu.cursor + 1}/#{length(choices)} · #{Enum.at(choices, context.menu.cursor).label}"
  defp face(nil, _selected), do: nil

  defp face(item, selected) do
    %{
      kind: :card,
      title: item.label,
      label: "#{item.label} · #{item.detail}",
      sub: item.detail,
      selected: selected,
      disabled: Map.get(item, :disabled, false)
    }
  end
end
