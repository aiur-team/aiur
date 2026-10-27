defmodule AiurWeb.Components.VoiceInputTest do
  # The conversation voice controller binds these data-voice-* selectors inside
  # its hook element and the drawer focus hook restores focus through
  # data-conversation-focus. Any surface that renders this component must keep
  # that contract or voice silently stops working there.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.Components.VoiceInput

  defp render(attrs \\ %{}) do
    html = render_component(&VoiceInput.voice_input/1, Map.merge(%{id: "drawer-voice"}, attrs))
    Floki.parse_fragment!(html)
  end

  defp one(document, selector) do
    assert [node] = Floki.find(document, selector), "expected exactly one #{selector}"
    node
  end

  defp attr(node, name), do: node |> Floki.attribute(name) |> List.first()

  test "renders every data-voice control the controller binds" do
    document = render()

    mic = one(document, "button[data-voice-mic]")
    assert attr(mic, "aria-label") == "Dictate message"
    assert attr(mic, "aria-pressed") == "false"
    assert attr(mic, "data-conversation-focus") == "dictation"

    conversation = one(document, "button[data-voice-conversation]")
    assert attr(conversation, "aria-label") == "Start interactive voice chat"
    assert attr(conversation, "data-conversation-focus") == "conversation"

    device = one(document, "select[data-voice-device]")
    assert attr(device, "aria-label") == "Browser microphone"

    waveform = one(document, "canvas[data-voice-waveform]")
    assert {attr(waveform, "width"), attr(waveform, "height")} == {"360", "52"}

    status = one(document, "p[data-voice-status]")
    assert attr(status, "role") == "status"
    assert attr(status, "aria-live") == "polite"
    assert Floki.text(status) =~ "Press the microphone to dictate. Review the text, then press Send."
  end

  test "leaves the composer textarea, send button and form to the caller" do
    document = render()

    assert Floki.find(document, "[data-voice-input]") == []
    assert Floki.find(document, "[data-voice-send]") == []
    assert Floki.find(document, "form") == []
  end

  test "omits the legacy conversation button when legacy_conversation is false" do
    document = render(%{legacy_conversation: false})

    assert Floki.find(document, "[data-voice-conversation]") == []
    assert [_mic] = Floki.find(document, "[data-voice-mic]")
  end

  test "renders caller-supplied status copy" do
    status = one(render(%{status_copy: "Hold to talk."}), "[data-voice-status]")

    assert String.trim(Floki.text(status)) == "Hold to talk."
  end
end
