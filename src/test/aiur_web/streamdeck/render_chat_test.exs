defmodule AiurWeb.Streamdeck.RenderChatTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Render.Chat

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
end
