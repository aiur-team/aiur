defmodule AiurWeb.Streamdeck.RenderChatTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Deck.Turns
  alias AiurWeb.Streamdeck.Render.Chat
  alias AiurWeb.Streamdeck.Render.Views

  test "frame chat wraps across 800 pixels with an inline role and escaped text" do
    [strip] = Chat.strip(%{state: "live", latest: %{k: "say", text: "<safe> " <> String.duplicate("wrap ", 150)}}, 0)
    assert strip.x == 0
    assert strip.width == 800
    assert strip.svg =~ "● &lt;safe&gt;"
    assert strip.svg =~ ~s(x="6")
    assert strip.svg =~ ~s(y="84")
    refute strip.svg =~ "<safe>"
  end

  test "missing and unavailable histories cannot render a blank or live strip" do
    for {state, label} <- [{"not_retained", "Conversation not retained"}, {"unavailable", "Conversation unavailable"}, {"restart_unknown", "Conversation state unknown after restart"}] do
      [strip] = Chat.strip(%{state: state, latest: nil}, 0)
      assert strip.label == label
      assert strip.svg =~ label
    end
  end

  test "stale frames name the age and retain the latest entry" do
    [strip] = Chat.strip(%{state: "stale", observed_at: 1_000, latest: %{k: "op", text: "reply"}}, 8_000)
    assert strip.label == "Conversation stale · 7s old › reply"
    assert strip.svg =~ "7s old"
    assert strip.svg =~ "› reply"
  end

  test "milestone breakpoints become selectable log keys" do
    [turn] = Turns.group([%{id: "bp:4:progress_25", k: "milestone", label: "Progress 25%", text: "Progress 25%", at: 1_000}])
    assert turn.id == "t:bp:4:progress_25"
    assert turn.text == "Progress 25%"

    key = elem(Views.compose(%{surface: :chat, nav: %{chat: %{turns: [turn], selected: turn.id, offset: 0}, surface: :chat}}), 0) |> Enum.find(&is_map/1)
    assert key.chat_turn == turn.id
    assert key.title == "Progress 25%"
  end
end
