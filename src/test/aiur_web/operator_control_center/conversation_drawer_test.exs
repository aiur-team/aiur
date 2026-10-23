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
      usage_snapshot: Keyword.get(opts, :usage_snapshot),
      usage_error: Keyword.get(opts, :usage_error, :no_usage_data),
      close_event: Keyword.get(opts, :close_event, "close-conversation"),
      fallback_focus_id: "units-title",
      origin_id: Keyword.get(opts, :origin_id, "units-conversation-token"),
      voice_capabilities: Keyword.get(opts, :voice_capabilities, %{})
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

  test "explains sending is unavailable while preserving conversation identity" do
    html = render(Presenter.present(row(), snapshot()))

    assert html =~ "You can read this conversation here. Sending is not available."
    refute html =~ "Read-only mirror"
    assert html =~ "Read-only dashboard — use the TUI to message or pause this agent."
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

  test "mounts the per-agent cumulative usage surface in the conversation drawer" do
    html = render(Presenter.present(row(), snapshot()))

    assert html =~ "Cumulative Token Usage"
    assert html =~ "Usage data unavailable"
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

  # The client reads these attributes to tell "voice is not configured" from
  # "voice failed" before the microphone is pressed; no visible copy changes.
  test "the voice input carries the published voice.stt state and reason" do
    composer = %{target_key: "1110", writable_target?: true, messages: []}
    view = Presenter.present(row(), snapshot())

    unconfigured = %{"voice.stt" => %{state: :unavailable, reason: :not_configured}, "voice.tts" => %{state: :unavailable, reason: :not_configured}}
    html = render(view, composer: composer, writable: true, voice_capabilities: unconfigured)
    assert html =~ ~s(data-voice-stt-state="unavailable")
    assert html =~ ~s(data-voice-stt-reason="not_configured")

    html = render(view, composer: composer, writable: true, voice_capabilities: %{"voice.stt" => %{state: :available}})
    assert html =~ ~s(data-voice-stt-state="available")
    refute html =~ "data-voice-stt-reason"

    html = render(view, composer: composer, writable: true)
    refute html =~ "data-voice-stt-state"
  end

  # Captured verbatim from the drawer before the voice controls moved into
  # AiurWeb.Components.VoiceInput. The voice controller and the drawer focus hook
  # bind these exact selectors, classes and labels.
  @pre_extraction_voice_tools """
    <div class="agent-voice-tools">
      <div class="agent-voice-controls">
        <button
          class="aiur-button aiur-button--tool aiur-button--dashboard-tool tool-btn agent-voice-button"
          type="button"
          aria-label="Dictate message"
          aria-pressed="false"
          title="Dictate into the message box"
          data-voice-mic
          data-conversation-focus="dictation"
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M12 14a3 3 0 0 0 3-3V5a3 3 0 1 0-6 0v6a3 3 0 0 0 3 3Z" />
            <path d="M5.5 10.5a6.5 6.5 0 0 0 13 0M12 17v4M8.5 21h7" />
          </svg>
        </button>
        <button
          class="aiur-button aiur-button--tool aiur-button--dashboard-tool tool-btn agent-voice-button"
          type="button"
          aria-label="Start interactive voice chat"
          aria-pressed="false"
          title="Talk to this agent and hear its reply"
          data-voice-conversation
          data-conversation-focus="conversation"
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <circle cx="8" cy="8" r="3" /><circle cx="17" cy="9" r="2.5" />
            <path d="M2.5 19c.5-3.3 2.4-5 5.5-5s5 1.7 5.5 5M13.5 15c1-.8 2.1-1.2 3.5-1.2 2.6 0 4.1 1.4 4.5 4.2M12 6.5l2-1.2M13.5 9.5l2 .8" />
          </svg>
        </button>
        <label class="agent-voice-device-label">
          <span>Browser microphone</span>
          <select data-voice-device aria-label="Browser microphone">
            <option value="">Default microphone</option>
          </select>
        </label>
      </div>
      <canvas
        class="agent-voice-waveform"
        width="360"
        height="52"
        aria-label="Microphone waveform"
        role="img"
        data-voice-waveform
      ></canvas>
      <p class="agent-voice-status" role="status" aria-live="polite" data-voice-status>
        Press the microphone to dictate. Review the text, then press Send.
      </p>
    </div>
  """

  test "voice tools subtree is identical to the pre-extraction markup (guards C1 extraction)" do
    composer = %{target_key: "1110", writable_target?: true, messages: []}
    html = render(Presenter.present(row(), snapshot()), composer: composer, writable: true)

    rendered = html |> Floki.parse_fragment!() |> Floki.find(".agent-voice-tools") |> normalize_tree()
    expected = @pre_extraction_voice_tools |> Floki.parse_fragment!() |> normalize_tree()

    assert rendered == expected
  end

  defp normalize_tree(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&normalize_tree/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_tree({tag, attrs, children}), do: {tag, Enum.sort(attrs), normalize_tree(children)}
  defp normalize_tree(text) when is_binary(text), do: String.trim(text)
  defp normalize_tree(_comment), do: ""

  test "renders the not-unique-writable-target notice when a composer is present but not writable" do
    composer = %{target_key: "1110", writable_target?: false, messages: []}
    html = render(Presenter.present(row(), snapshot()), composer: composer, writable: true)

    refute html =~ ~s(<textarea)
    refute html =~ ~s(phx-submit="send-operator-message")
    assert html =~ "You can read this conversation here. Sending is not available."
    refute html =~ "Read-only mirror"
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
