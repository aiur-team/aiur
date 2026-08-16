defmodule AiurWeb.OperatorControlCenter.ConversationDrawerTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.ConversationDrawer
  alias AiurWeb.OperatorControlCenter.ConversationDrawer.Presenter

  @observed_at ~U[2026-07-17 12:00:00Z]
  @handle "conversation:" <> String.duplicate("a", 43)

  defp identity do
    struct!(TrackerIdentity,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "NODE-1110",
      database_id: 1110,
      identifier: "1110"
    )
  end

  defp row do
    %{
      title: "Responsive Units interface",
      identity: identity(),
      agent_family: :codex,
      backend: :codex,
      requested_model: "gpt-5.6-terra",
      resolved_model: "gpt-5.6-terra-2026",
      live_conversation: %{generation_handle: @handle}
    }
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        state: :live,
        health: :healthy,
        freshness: :current,
        messages: [
          %{
            id: "m1",
            role: "agent",
            title: "Assistant",
            body: "Working on the drawer.",
            occurred_at: @observed_at,
            observed_at: @observed_at
          }
        ],
        observed_at: @observed_at,
        truncated?: false,
        evicted_count: 0,
        source: %{worker_generation: 4, session_id: "opaque-session"}
      },
      overrides
    )
  end

  defp render(view, opts \\ []) do
    render_component(&ConversationDrawer.conversation_drawer/1, %{
      id: "units-conversation-drawer",
      view: view,
      composer: Keyword.get(opts, :composer),
      writable: Keyword.get(opts, :writable, false),
      close_event: Keyword.get(opts, :close_event, "close-conversation"),
      fallback_focus_id: "units-title",
      origin_id: Keyword.get(opts, :origin_id, "units-conversation-token")
    })
  end

  test "renders a semantic modal dialog wired for accessible focus and close" do
    html = render(Presenter.present(row(), snapshot()))

    assert html =~ ~s(id="units-conversation-drawer")
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ ~s(aria-labelledby="units-conversation-drawer-title")
    assert html =~ ~s(phx-hook="ConversationDrawer")
    assert html =~ ~s(data-close-event="close-conversation")
    assert html =~ ~s(data-focus-fallback-id="units-title")
    assert html =~ ~s(data-origin-id="units-conversation-token")
    assert html =~ ~s(data-dialog-heading)
    assert html =~ ~s(data-conversation-focus="heading")
    assert html =~ ~s(data-conversation-focus="close")
    assert html =~ ~s(phx-click="close-conversation")
    assert html =~ ~s(role="log")
  end

  test "states the reader is not participating and mirrors identity, not participation" do
    html = render(Presenter.present(row(), snapshot()))

    assert html =~ "not participating"
    assert html =~ "its-everdred/aiur #1110"
    assert html =~ "Responsive Units interface"
  end

  test "renders non-color state, health, and freshness chips" do
    html = render(Presenter.present(row(), snapshot()))

    assert html =~ ~s(data-state="live")
    assert html =~ "Live"
    assert html =~ "Health: Healthy"
    assert html =~ "Freshness: Current"
  end

  test "renders bounded messages with role labels and iso timestamps" do
    html = render(Presenter.present(row(), snapshot()))

    assert html =~ "Agent"
    assert html =~ "Working on the drawer."
    assert html =~ ~s(data-message-complete="true")
    assert html =~ ~s(datetime="2026-07-17T12:00:00Z")
  end

  test "renders an aria-live log only while live" do
    live = render(Presenter.present(row(), snapshot(%{state: :live})))
    ended = render(Presenter.present(row(), snapshot(%{state: :ended})))

    assert live =~ ~s(aria-live="polite")
    assert live =~ ~s(data-live="true")
    assert ended =~ ~s(aria-live="off")
    assert ended =~ ~s(data-live="false")
  end

  test "renders a truthful empty state for a known-empty conversation" do
    html = render(Presenter.present(row(), snapshot(%{state: :known_empty, messages: []})))

    assert html =~ "No conversation has been recorded for this worker yet."
    refute html =~ ~s(<ol class="conversation-drawer-messages")
  end

  test "renders the agent log transcript beneath the conversation when present" do
    log = %{
      messages: [
        %{role: "assistant", title: "Agent", timestamp: "2026-07-17T11:30:00Z", body: "Building the grid."},
        %{role: "tool", title: "Run `make ci`", timestamp: "2026-07-17T11:31:00Z", body: "make ci passed"}
      ]
    }

    html = render(Presenter.present(row(), snapshot(), :active, log))

    assert html =~ "Agent log"
    assert html =~ "Building the grid."
    assert html =~ "make ci passed"
    assert html =~ "Run `make ci`"
    assert html =~ "2026-07-17T11:30:00Z"
    assert html =~ "conversation-log-tool"
  end

  test "omits the agent log section when no log is provided" do
    html = render(Presenter.present(row(), snapshot()))

    refute html =~ "Agent log"
    refute html =~ "conversation-log-"
  end

  test "renders the truncation note when older messages are evicted" do
    html = render(Presenter.present(row(), snapshot(%{truncated?: true, evicted_count: 2})))
    assert html =~ "2 earlier"
  end

  test "renders nothing for a nil view" do
    assert render(nil) == ""
  end

  test "carries no message, pause, or capacity mutation handler" do
    html = render(Presenter.present(row(), snapshot()))

    refute html =~ "send-operator-message"
    refute html =~ "pause-agent"
    refute html =~ "composer-change"
    refute html =~ ~s(<form)
    refute html =~ ~s(<textarea)
  end

  test "renders the writable composer when a unique target is provided" do
    composer = %{target_key: "1110", writable_target?: true, messages: []}
    html = render(Presenter.present(row(), snapshot()), composer: composer, writable: true)

    assert html =~ ~s(phx-submit="send-operator-message")
    assert html =~ ~s(phx-change="composer-change")
    assert html =~ ~s(phx-click="pause-agent")
    assert html =~ ~s(<textarea)
    assert html =~ "Message agent…"
    refute html =~ "Read-only dashboard"
    refute html =~ "not a unique writable target"
  end

  test "renders dictation and interactive conversation controls in the standard composer" do
    composer = %{target_key: "1110", writable_target?: true, messages: []}
    html = render(Presenter.present(row(), snapshot()), composer: composer, writable: true)

    assert html =~ ~s(data-voice-composer)
    assert html =~ ~s(data-voice-mic)
    assert html =~ ~s(aria-label="Dictate message")
    assert html =~ ~s(data-voice-waveform)
    assert html =~ ~s(aria-label="Microphone waveform")
    assert html =~ ~s(data-voice-device)
    assert html =~ "Browser microphone"
    assert html =~ ~s(data-voice-status)

    assert html =~ ~s(data-voice-conversation)
    assert html =~ ~s(aria-label="Start interactive voice chat")
    assert html =~ "Talk to this agent and hear its reply"
    refute html =~ "Interactive voice chat is not available yet"
  end

  test "renders the not-unique-writable-target notice when a composer is present but not writable" do
    composer = %{target_key: "1110", writable_target?: false, messages: []}
    html = render(Presenter.present(row(), snapshot()), composer: composer, writable: true)

    refute html =~ ~s(<textarea)
    refute html =~ ~s(phx-submit="send-operator-message")
    assert html =~ "not a unique writable target"
  end

  test "never leaks the generation handle, session material, or a local path" do
    view = Presenter.present(row(), snapshot(%{source: %{worker_generation: 4, session_id: "raw-secret-session"}}))
    html = render(view)

    refute html =~ @handle
    refute html =~ "raw-secret-session"
    refute html =~ "/private/"
    refute html =~ ".jsonl"
  end

  test "ignores an unsafe close event and injected origin identifiers" do
    html = render(Presenter.present(row(), snapshot()), close_event: "javascript:alert(1)", origin_id: "bad id!")

    refute html =~ "javascript:alert(1)"
    refute html =~ ~s(data-origin-id="bad id!")
  end
end
