defmodule AiurWeb.Streamdeck.Render.Views do
  @moduledoc "Existing focused views expressed as common renderer faces and strip parts."
  alias AiurWeb.Streamdeck.Deck.{ChatNavigation, EpicFrame, Nav}
  alias AiurWeb.Streamdeck.Render.{Fleet, MeterDetail, Settings, Svg, ViewStrip}
  import Svg, only: [field: 2, field: 3]

  @glyphs %{
    "pause" => "Ⅱ",
    "play" => "▶",
    "logs" => "≡",
    "mic" => "●",
    "settings" => "⚙",
    "commands" => "?",
    "up" => "↑",
    "down" => "↓"
  }
  @microphone "Settings are saved by the connected daemon. Microphone and speaker choices use inventory reported by the PC sidecar."
  @voice "Speech is transcribed by Aiur, not by the deck: audio is streamed to Aiur over the authenticated channel and Aiur calls ElevenLabs. The sidecar never holds the API key."

  @spec compose(map()) :: {[map() | nil], [map()]}
  def compose(%{surface: :grid, nav: %{stack: [{:meter_detail, provider} | _]} = nav, grid: grid}) do
    MeterDetail.compose(grid.meter_detail, Map.get(grid.meter_usage, provider, %{}), grid.meter_now_ms, Nav.page(nav))
  end

  def compose(%{nav: %{chat: chat, surface: :chat}} = model) when is_map(chat) do
    turns = ChatNavigation.visible(chat)

    faces =
      Enum.map(turns, fn turn ->
        card(turn.text, turn.text, "#{turn.tools} tools", chat_turn: turn.id, selected: turn.id == chat.selected)
      end)

    faces = List.duplicate(nil, 7 - length(faces)) ++ faces
    {faces ++ [card("LIVE", "LIVE", "", live: true, selected: is_nil(chat.selected))], chat_regions(model)}
  end

  def compose(%{nav: %{view: :epic} = nav} = model) when not is_map_key(model, :surface) or model.surface in [:grid, "grid"],
    do: with_toast(EpicFrame.compose(field(model, :grid) || model, nav), model)

  def compose(%{nav: %{view: :fleet} = nav} = model) when not is_map_key(model, :surface) or model.surface in [:grid, "grid"] do
    with_toast(Fleet.compose(field(model, :grid) || model, nav, field(model, :usage) || %{}), model)
  end

  def compose(model) do
    context = field(model, :view_context, %{})
    compose(to_string(field(model, :surface)), model, context)
  end

  defp compose("settings", _model, context), do: Settings.compose(field(context, :settings))

  defp compose(surface, model, context) do
    faces = keys(surface, context)
    faces = Enum.take(faces ++ List.duplicate(nil, 8), 8)
    {faces, ViewStrip.compose(model, context)}
  end

  defp chat_regions(model) do
    case field(model, :toast) do
      text when is_binary(text) -> [%{x: 0, width: 800, label: text, parts: [%{kind: :text_line, text: text, y: 50, size: 12}]}]
      _ -> ViewStrip.compose(model, %{})
    end
  end

  @spec settings_text() :: [String.t()]
  def settings_text, do: [@microphone, @voice]

  defp with_toast({faces, regions}, model) do
    toast = field(model, :toast)
    regions = if is_binary(toast), do: List.replace_at(regions, 0, %{x: 0, width: 200, label: toast, parts: [%{kind: :text_line, text: toast, y: 50, size: 12}]}), else: regions
    {faces, regions}
  end

  defp keys("cmd", context) do
    context
    |> field(:command_keys, [])
    |> Enum.map(fn
      %{empty?: true} ->
        nil

      key ->
        card(key.label, key.label, key.sub, glyph: @glyphs[key.icon], command: key.command, state: key.state, disabled: key.disabled?, hold: key.mic?, icon: key.icon, url: Map.get(key, :url))
    end)
  end

  defp keys("commands", context) do
    keys = field(context, :decision_keys, [])

    Enum.map(keys, fn
      %{empty?: true} ->
        nil

      %{decision_id: id} = key ->
        card(key.question, nonempty(key.question, "Command"), key.status,
          decision_id: id,
          option_index: key.index
        )

      key ->
        card(key.label, "Option: #{key.label}", "OPT #{key.index + 1}",
          option_index: key.index,
          selected: key.index == field(context, :commands_option)
        )
    end)
    |> maybe_mic(context)
  end

  defp keys(_surface, _context), do: []

  defp maybe_mic(keys, context) do
    if field(context, :commands_view) == :detail,
      do: keys ++ [card("Mic", "Mic", "SIDECAR", disabled: true)],
      else: keys
  end

  defp card(title, label, sub, extra),
    do:
      Map.merge(
        %{kind: :card, title: title, label: nonempty(label, "Key"), sub: sub},
        Map.new(extra)
      )

  defp nonempty(value, fallback),
    do: if(is_binary(value) and value != "", do: value, else: fallback)
end
