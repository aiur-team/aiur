defmodule AiurWeb.Streamdeck.Render.Views do
  @moduledoc "Existing focused views expressed as common renderer faces and strip parts."
  alias AiurWeb.Streamdeck.Deck.Nav
  alias AiurWeb.Streamdeck.Render.{MeterDetail, Svg, ViewStrip}
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
  @microphone "Microphone selection lives on the machine running the sidecar. The browser emulator has no access to those devices, so there is nothing to choose here."
  @voice "Speech is transcribed by Aiur, not by the deck: audio is streamed to Aiur over the authenticated channel and Aiur calls ElevenLabs. The sidecar never holds the API key."

  @spec compose(map()) :: {[map() | nil], [map()]}
  def compose(%{surface: :grid, nav: %{stack: [{:meter_detail, provider} | _]} = nav, grid: grid}) do
    MeterDetail.compose(grid.meter_detail, Map.get(grid.meter_usage, provider, %{}), grid.meter_now_ms, Nav.page(nav))
  end

  def compose(model) do
    context = field(model, :view_context, %{})
    faces = keys(to_string(field(model, :surface)), context)
    faces = Enum.take(faces ++ List.duplicate(nil, 8), 8)
    {faces, ViewStrip.compose(model, context)}
  end

  @spec settings_text() :: [String.t()]
  def settings_text, do: [@microphone, @voice]

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

  defp keys("logs", context) do
    context
    |> field(:logs, %{})
    |> field(:event_keys_visible, [])
    |> Enum.map(fn
      %{kind: :empty} ->
        nil

      %{kind: :live} = key ->
        card("LIVE", "LIVE", "",
          event_index: key.index,
          live: true,
          selected: key.index == field(field(context, :logs), :selected_event_index)
        )

      key ->
        card(key.text, "#{key.badge}: #{key.text}, #{key.time}", key.time,
          badge: key.badge,
          event_index: key.index,
          glyph: key.badge,
          selected: key.index == field(field(context, :logs), :selected_event_index)
        )
    end)
  end

  defp keys("settings", _context),
    do: [
      card("Microphone", @microphone, "SIDECAR", disabled: true),
      card("Voice", @voice, "DAEMON", disabled: true)
    ]

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
