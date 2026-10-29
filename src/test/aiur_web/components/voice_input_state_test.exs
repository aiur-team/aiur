defmodule AiurWeb.Components.VoiceInputStateTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AiurWeb.Components.VoiceInput

  test "unavailable is server-rendered with the actual reason and configuration link" do
    for {reason, copy} <- [
          {:not_configured, "Voice input is not configured."},
          {:not_installed, "Voice input isn't installed in this Aiur. Typed messages work as usual."}
        ] do
      html = render_component(&VoiceInput.voice_input/1, %{id: "voice", capabilities: %{"voice.stt" => %{state: :unavailable, reason: reason}}})
      document = Floki.parse_fragment!(html)
      assert Floki.attribute(Floki.find(document, "[data-voice-root]"), "data-voice-state") == ["unavailable"]
      assert Floki.attribute(Floki.find(document, "[data-voice-mode=dictate]"), "aria-disabled") == ["true"]
      assert document |> Floki.find("[data-voice-status]") |> Floki.text() |> String.trim() == copy

      if reason == :not_configured do
        assert Floki.attribute(Floki.find(document, "a"), "href") == ["https://aiur.team/docs/apis/elevenlabs#configure-the-key"]
      end
    end
  end

  test "available speech to text starts idle with the review then Send instruction" do
    html = render_component(&VoiceInput.voice_input/1, %{id: "voice", capabilities: %{"voice.stt" => %{state: :available}}})
    document = Floki.parse_fragment!(html)
    assert Floki.attribute(Floki.find(document, "[data-voice-root]"), "data-voice-state") == ["idle"]
    assert document |> Floki.find("[data-voice-status]") |> Floki.text() |> String.trim() == "Press the microphone to dictate. Review the text, then press Send."
  end
end
