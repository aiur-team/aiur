defmodule AiurWeb.OperatorControlCenter.ExecutorVoice do
  @moduledoc "Standalone Executor conversation control, separate from agent dictation."
  use Phoenix.Component

  attr(:id, :string, required: true)
  attr(:writable, :boolean, default: false)

  @spec executor_voice(map()) :: Phoenix.LiveView.Rendered.t()
  def executor_voice(assigns) do
    settings = Aiur.Config.voice_conversation()
    assigns = assigns |> assign(:available, settings.cloud_disclosure_accepted == true) |> assign(:settings, settings)

    ~H"""
    <section id={@id} phx-update="ignore" data-executor-voice data-configured={to_string(@available)} data-state={if @available, do: "idle", else: "not_configured"} aria-label="Executor voice conversation">
      <label for={@id <> "-provider"}>Conversation provider</label>
      <select id={@id <> "-provider"} data-executor-voice-provider disabled={!@writable}>
        <option value="elevenlabs_agents" selected={@settings.provider == :elevenlabs_agents}>ElevenLabs</option>
        <option value="openai_realtime" selected={@settings.provider == :openai_realtime}>OpenAI</option>
      </select>
      <label for={@id <> "-model"}>Model for this session</label>
      <input id={@id <> "-model"} data-executor-voice-model value={@settings.llm} maxlength="120" required disabled={!@writable} />
      <p>Both providers use the same briefing, read-only tools and Executor handoff. Provider credentials and cloud disclosure must be configured.</p>
      <p data-executor-voice-meter role="status" aria-live="polite">Comparison usage unavailable.</p>
      <button type="button" class="aiur-button aiur-button--dashboard btn" data-executor-voice-toggle disabled={!@available or !@writable}>
        Talk to Executor
      </button>
      <p role="status" aria-live="polite" data-executor-voice-status>
        {if @available, do: "Choose a provider and model. Credentials are checked at Start.", else: "Accept cloud disclosure in voice settings to enable Executor voice."}
      </p>
      <p data-executor-voice-transcript></p>
      <pre class="agent-voice-status" data-executor-voice-receipt role="status" aria-live="polite"></pre>
      <details data-executor-voice-compare>
        <summary>Compare providers and record Kevin’s rating</summary>
        <p>Cost estimates allocate USD 8 to 45 OpenAI minutes and USD 8 to 45 ElevenLabs minutes. Check actual account spend before each run.</p>
        <p>First audio measures server receipt after Start, before browser playback. Reserved minutes include active or interrupted sessions.</p>
        <div style="overflow-x: auto">
          <table>
            <thead><tr><th scope="col">ElevenLabs</th><th scope="col">OpenAI</th></tr></thead>
            <tbody data-executor-voice-comparisons></tbody>
          </table>
        </div>
        <p data-executor-voice-comparison-status role="status" aria-live="polite"></p>
      </details>
    </section>
    """
  end
end
