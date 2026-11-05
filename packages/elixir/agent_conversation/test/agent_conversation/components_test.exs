defmodule AgentConversation.ComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias AgentConversation.{Client, Components, FixtureTransport, HostFixture}

  defp entry(attrs) do
    Map.merge(%{pos: 1, kind: "message", role: "agent", body: "hello"}, attrs)
  end

  defp render_entry(attrs, opts \\ []) do
    item = AgentConversation.Entry.normalize(entry(attrs))
    render_component(&Components.entry/1, Keyword.merge([entry: item], opts))
  end

  defp mounted(conversation_id, entries, opts \\ []) do
    {:ok, host} = HostFixture.host(conversation_id, opts)
    FixtureTransport.put_conversation(conversation_id, entries, opts)
    {:ok, client} = Client.mount(host, conversation_id, Keyword.take(opts, [:motion, :viewport]))
    client
  end

  test "the host renderer, not the package, renders an entry body" do
    plain = render_entry(%{body: "**hello**"})
    assert plain =~ "**hello**"
    refute plain =~ "<strong>"

    hosted = render_entry(%{body: "**hello**"}, renderer: &HostFixture.content/1)
    assert hosted =~ ~s(data-host-renderer="true")
    assert hosted =~ ~s(<strong>**hello**</strong>)
    assert hosted =~ ~s(data-pos="1")
  end

  test "truncation notices and masked entries stay explicit" do
    rendered =
      render_entry(%{
        body_truncated: true,
        body: "…[123 bytes omitted]…",
        output_truncated: true,
        output: "…[456 bytes omitted]…"
      })

    assert rendered =~ "Middle of this output not stored (123 bytes)"
    assert rendered =~ "Middle of this output not stored (456 bytes)"
    assert render_entry(%{redacted: true}) =~ "masked"
    refute render_entry(%{redacted: true}) =~ "Show raw"
    assert render_entry(%{redacted: true}, can_reveal: true) =~ "Show raw"
  end

  test "images, animated images, video and audio each render an inline element" do
    media = [
      %{kind: "image", name: "shot.png", url: "https://cdn.example/shot.png"},
      %{kind: "gif", name: "loop.gif", url: "https://cdn.example/loop.gif"},
      %{kind: "video", name: "clip.mp4", url: "https://cdn.example/clip.mp4"},
      %{kind: "audio", name: "voice.ogg", url: "https://cdn.example/voice.ogg"}
    ]

    rendered = render_entry(%{media: media})
    document = Floki.parse_fragment!(rendered)

    assert [_] = Floki.find(document, ~s(figure[data-media-kind="image"] img[src="https://cdn.example/shot.png"]))
    assert [_] = Floki.find(document, ~s(figure[data-media-kind="animated_image"] img[data-animated="true"]))
    assert [_] = Floki.find(document, "figure video[src]")
    assert [_] = Floki.find(document, "figure audio[src]")
    assert Floki.attribute(document, "img", "alt") != []
  end

  test "reduced motion replaces an animated image with a still link" do
    media = [%{kind: "gif", name: "loop.gif", url: "https://cdn.example/loop.gif"}]
    document = render_entry(%{media: media}, motion: :reduced) |> Floki.parse_fragment!()

    assert [] = Floki.find(document, "img[data-animated]")
    assert [_] = Floki.find(document, ~s(a[data-motion="reduced"][href="https://cdn.example/loop.gif"]))
  end

  test "an unsupported attachment falls back to a named link, never an element" do
    media = [%{kind: "binary", name: "archive.zip", url: "https://cdn.example/archive.zip"}]
    document = render_entry(%{media: media}) |> Floki.parse_fragment!()

    assert [_] =
             Floki.find(
               document,
               ~s(.conversation-media[data-media-fallback] a[href="https://cdn.example/archive.zip"])
             )

    assert [] = Floki.find(document, ".conversation-media img")
    assert Floki.text(document) =~ "unsupported attachment"
  end

  test "the minimap renders one labelled tick per row and never uses transcript positions" do
    rows = [%{pos: 3, kind: "message", label: "Message", at: nil}, %{pos: 7, kind: "diff", label: "Diff", at: "now"}]

    document =
      render_component(&Components.minimap/1, rows: rows, active_pos: 7) |> Floki.parse_fragment!()

    ticks = Floki.find(document, "button[data-tick-pos]")
    assert length(ticks) == 2
    assert [] = Floki.find(document, "[data-pos]")
    assert Floki.attribute(document, "button[aria-current='location']", "data-tick-pos") == ["7"]
    assert Enum.all?(Floki.attribute(document, "button[data-tick-pos]", "aria-label"), &(&1 =~ "position"))
  end

  test "a Command card shows its question and hands answering to the host" do
    row = AgentConversation.Commands.normalize(%{id: "cmd-1", question: "Ship it?", pos: 4})

    document =
      render_component(&Components.command_card/1,
        row: row,
        slot: {:at_pos, 4},
        href: "/commands/cmd-1",
        answerable: true,
        actions: &HostFixture.actions/1
      )
      |> Floki.parse_fragment!()

    assert Floki.text(document) =~ "Ship it?"
    assert [_] = Floki.find(document, ~s(a[href="/commands/cmd-1"]))
    assert [_] = Floki.find(document, ~s(button.host-answer[data-command-id="cmd-1"]))
  end

  test "a Command answered elsewhere shows the conflict notice and disables answering" do
    row = AgentConversation.Commands.normalize(%{id: "cmd-2", question: "Restart?", pos: 1})
    notice = AgentConversation.Commands.notice(%{"cmd-2" => %{outcome: :already_answered}}, "cmd-2")

    document =
      render_component(&Components.command_card/1,
        row: row,
        slot: :pinned_top,
        notice: notice,
        answerable: false,
        actions: &HostFixture.actions/1
      )
      |> Floki.parse_fragment!()

    assert Floki.text(document) =~ "Another answer landed first"
    assert Floki.text(document) =~ "Position unknown"
    assert [_] = Floki.find(document, "button.host-answer[disabled]")
  end

  test "voice controls follow the reported capability state" do
    unavailable =
      render_component(&Components.composer/1,
        voice: AgentConversation.Voice.from_report({:error, :unavailable}),
        voice_available: true,
        writable: true
      )
      |> Floki.parse_fragment!()

    assert Floki.text(unavailable) =~ "Voice is not available in this embed"
    assert Enum.map(Floki.find(unavailable, ".conversation-voice-controls button"), &Floki.text/1) == []

    denied =
      render_component(&Components.composer/1,
        voice: AgentConversation.Voice.from_report({:error, :permission_denied}),
        voice_available: true,
        writable: true
      )
      |> Floki.parse_fragment!()

    assert Floki.text(denied) =~ "Voice is not permitted for this account"

    available =
      render_component(&Components.composer/1,
        voice: AgentConversation.Voice.from_report({:ok, %{dictation: true, two_way: true}}),
        voice_available: true,
        writable: true,
        start_voice_event: "start_voice"
      )
      |> Floki.parse_fragment!()

    assert Floki.attribute(available, "button[phx-value-mode]", "phx-value-mode") == ["dictation", "two_way"]
  end

  test "a read-only host states it instead of rendering a dead composer" do
    document =
      render_component(&Components.composer/1,
        voice: AgentConversation.Voice.from_report({:error, :unavailable}),
        writable: false
      )
      |> Floki.parse_fragment!()

    assert Floki.text(document) =~ "Read-only"
    assert [] = Floki.find(document, "#conversation-composer")
  end

  test "the mounted conversation carries keyboard, focus, motion and viewport hooks" do
    client =
      mounted("conv-render", [%{pos: 1, kind: "message", role: "agent", body: "one"}],
        motion: :reduced,
        viewport: :narrow
      )

    document =
      render_component(&Components.conversation/1, client: client, entry_content: &HostFixture.content/1)
      |> Floki.parse_fragment!()

    assert Floki.attribute(document, ".conversation-page", "data-motion") == ["reduced"]
    assert Floki.attribute(document, ".conversation-page", "data-viewport") == ["narrow"]
    assert Floki.attribute(document, "#conversation-scroll", "tabindex") == ["0"]
    assert Floki.attribute(document, "#conversation-scroll", "data-keyboard-nav") == ["entries"]
    assert Floki.attribute(document, "#conversation-scroll", "role") == ["region"]
    assert Floki.attribute(document, ".conversation-entry", "tabindex") == ["-1"]
    assert Floki.attribute(document, ".conversation-minimap", "aria-label") != []
  end

  test "the mounted conversation renders an empty state with no transcript rows" do
    client = mounted("conv-empty", [])

    document =
      render_component(&Components.conversation/1, client: client, entry_content: &HostFixture.content/1)
      |> Floki.parse_fragment!()

    assert Floki.text(document) =~ "No messages yet"
    assert [] = Floki.find(document, ".conversation-entry")
  end
end
