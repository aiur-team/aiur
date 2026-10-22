defmodule AiurWeb.Components.VoiceInput do
  @moduledoc """
  Reusable browser voice controls for a message composer.

  Renders the dictation button, the interactive voice chat button, the
  microphone picker, the waveform canvas and the live status line. The
  `data-voice-*` attributes are the DOM contract that the conversation voice
  controller binds inside its hook element. The caller keeps the form, the
  `data-voice-input` textarea and the `data-voice-send` button, because each
  surface owns its own submit event.
  """

  use Phoenix.Component

  @default_status_copy "Press the microphone to dictate. Review the text, then press Send."

  attr(:id, :string, required: true, doc: "prefix reserved for ids rendered by the component")
  attr(:legacy_conversation, :boolean, default: true, doc: "render the interactive voice chat button")
  attr(:status_copy, :string, default: @default_status_copy)

  @spec voice_input(map()) :: Phoenix.LiveView.Rendered.t()
  def voice_input(assigns) do
    ~H"""
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
          :if={@legacy_conversation}
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
        {@status_copy}
      </p>
    </div>
    """
  end
end
