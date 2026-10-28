defmodule AiurWeb.OperatorControlCenter.ExecutorVoice do
  @moduledoc "Standalone Executor conversation control, separate from agent dictation."
  use Phoenix.Component

  attr(:id, :string, required: true)
  attr(:writable, :boolean, default: false)

  @spec executor_voice(map()) :: Phoenix.LiveView.Rendered.t()
  def executor_voice(assigns) do
    assigns = assign(assigns, :available, Aiur.VoiceConversation.availability() == :ok)

    ~H"""
    <section id={@id} phx-update="ignore" data-executor-voice data-configured={to_string(@available)} data-state={if @available, do: "idle", else: "not_configured"} aria-label="Executor voice conversation">
      <button type="button" class="aiur-button aiur-button--dashboard btn" data-executor-voice-toggle disabled={!@available or !@writable}>
        Talk to Executor
      </button>
      <p role="status" aria-live="polite" data-executor-voice-status>
        {if @available, do: "Executor voice ready.", else: "Executor voice not configured."}
      </p>
      <p data-executor-voice-transcript></p>
      <pre class="agent-voice-status" data-executor-voice-receipt role="status" aria-live="polite"></pre>
    </section>
    """
  end
end
