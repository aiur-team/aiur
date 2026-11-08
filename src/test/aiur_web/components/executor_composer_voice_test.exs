defmodule AiurWeb.ExecutorComposerVoiceTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias Aiur.Conversation.Ref
  alias AiurWeb.Conversation.Composer

  test "enabled Executor composer puts voice controls and text inside the VoiceInput form" do
    html = render()
    form = Floki.find(html, "form[phx-hook=VoiceInput]")
    assert Floki.find(form, "textarea[data-voice-input]") != []
    assert Floki.find(form, "button[data-voice-send]") != []
    assert Floki.find(form, "[data-voice-mode=dictate][aria-disabled=false]") != []
    assert Floki.find(form, "[data-voice-mode=converse][aria-disabled=false]") != []
    assert [target] = Floki.attribute(form, "[data-voice-surface=executor_composer]", "data-voice-target")
    assert Jason.decode!(target) == %{"kind" => "executor", "instance_id" => "machine/run"}
    assert Floki.find(form, "[data-voice-conversation]") == []
  end

  test "read-only, missing target and unknown effective mode hide voice" do
    for attrs <- [%{writable: false}, %{target: nil}, %{listener: %{effective: nil}}, %{listener: nil}] do
      html = render(attrs)
      assert Floki.find(html, "[data-voice-root]") == []
      assert Floki.find(html, "[phx-hook=VoiceInput]") == []
    end

    assert Floki.find(render(%{listener: %{effective: nil}, capability: {:unavailable, :executor_delivery_not_installed}}), "textarea[disabled]") != []
  end

  test "worker composer shows canonical async and mute copy while retaining its message form" do
    for {mode, copy} <- [async: "Async · pings only", mute: "Mute · silent"] do
      html = render(%{target: %{ticket: "123"}, listener: %{effective: mode}})
      assert Floki.text(Floki.find(html, ".conversation-mode")) =~ copy
      assert Floki.find(html, "form#conversation-composer textarea:not([disabled])") != []
      refute Floki.text(html) =~ "mode unknown"
    end
  end

  # Existing behavior guard, not coverage of the Executor addition.
  test "future regression guard: worker composers keep their existing controls" do
    html = render(%{target: %{ticket: "123"}})
    assert Floki.find(html, "form#conversation-composer") != []
    assert Floki.find(html, "[data-voice-root]") == []
    assert Floki.text(html) =~ "Message to agent"
  end

  defp render(attrs \\ %{}) do
    defaults = %{
      writable: true,
      capability: :available,
      target: Ref.executor(),
      draft: "keep this text",
      overlay: %{},
      listener: %{effective: :sync},
      instance_id: "machine/run",
      voice_capabilities: %{"voice.stt" => %{state: :available}, "voice.conversation" => %{state: :available}}
    }

    render_component(&Composer.composer/1, Map.merge(defaults, attrs)) |> Floki.parse_fragment!()
  end
end
