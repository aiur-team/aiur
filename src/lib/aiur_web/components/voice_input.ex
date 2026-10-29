defmodule AiurWeb.Components.VoiceInput do
  @moduledoc """
  Reusable browser voice controls for a message composer.

  Renders the dictation button, the interactive voice chat button, the
  microphone picker, the waveform canvas and the live status line. The
  `data-voice-*` attributes are the DOM contract that the conversation voice
  controller binds inside its hook element. The caller keeps the form, the
  `data-voice-input` textarea and the `data-voice-send` button, because each
  surface owns its own submit event. Put `phx-hook="VoiceInput"` on that form,
  or pass `hook="VoiceInput"` here and supply the textarea and Send button
  through the optional inner block so all controls share the hook boundary.
  """

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.AgentLogModal

  @d16_layout :chooser

  @default_status_copy "Press the microphone to dictate. Review the text, then press Send."

  attr(:id, :string, required: true, doc: "prefix reserved for ids rendered by the component")
  attr(:hook, :string, default: nil, doc: "optional VoiceInput hook; put the composer in inner_block when set")
  slot(:inner_block, doc: "optional caller-owned textarea and Send button, inside the hook boundary")
  attr(:legacy_conversation, :boolean, default: true, doc: "render the interactive voice chat button")
  attr(:status_copy, :string, default: @default_status_copy)
  attr(:capabilities, :map, default: %{}, doc: "`voice.*` capability report entries; controls availability of Dictate and Converse")

  attr(:layout, :atom, values: [:buttons, :chooser], default: @d16_layout)
  attr(:surface, :string, default: "agent_composer")
  attr(:target, :map, default: %{})

  attr(:delivery, :map, default: nil, doc: "canonical composer receipt; voice never creates delivery observations")

  @spec voice_input(map()) :: Phoenix.LiveView.Rendered.t()
  def voice_input(assigns) do
    assigns =
      assigns
      |> assign(:stt, Map.get(assigns.capabilities, "voice.stt", %{}))
      |> assign(:dictate, mode({"dictate", "Dictate", "voice.stt"}, assigns.capabilities))
      |> assign(:modes, Enum.map([{"dictate", "Dictate", "voice.stt"}, {"converse", "Converse", "voice.conversation"}], &mode(&1, assigns.capabilities)))
      |> assign(:legacy_conversation, assigns.legacy_conversation and to_string(get_in(assigns.capabilities, ["voice.conversation", :state])) not in ["available", "degraded"])

    ~H"""
    <div id={@id} phx-hook={@hook} class="agent-voice-tools" data-voice-root data-voice-surface={@surface} data-voice-target={Jason.encode!(@target)}
      data-voice-stt-state={@stt[:state]} data-voice-stt-reason={@stt[:reason]} data-voice-delivery-accepted={to_string(accepted?(@delivery))} data-voice-state={if !@dictate.available, do: "unavailable", else: if(accepted?(@delivery), do: "sent", else: "idle")}>
      {render_slot(@inner_block)}
      <div class="agent-voice-controls">
        <div class="agent-voice-choice">
          <button :if={@layout == :chooser} type="button" class="aiur-button aiur-button--tool aiur-button--dashboard-tool tool-btn agent-voice-button" data-voice-chooser
            aria-label="Choose voice input" aria-haspopup="menu" aria-expanded="false" aria-controls={"#{@id}-menu"}
            data-conversation-focus="voice-choice">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M12 14a3 3 0 0 0 3-3V5a3 3 0 1 0-6 0v6a3 3 0 0 0 3 3Z" />
              <path d="M5.5 10.5a6.5 6.5 0 0 0 13 0M12 17v4M8.5 21h7" />
            </svg>
          </button>
          <div id={"#{@id}-menu"} role={if @layout == :chooser, do: "menu"} aria-label="Voice input"
            data-voice-menu hidden={@layout == :chooser}>
            <button :for={mode <- @modes} type="button" class="aiur-button aiur-button--dashboard btn agent-voice-mode"
              role={if @layout == :chooser, do: "menuitem"} data-voice-mode={mode.id}
              data-voice-mic={if mode.id == "dictate", do: ""} data-conversation-focus={mode.id}
              aria-label={if mode.id == "dictate", do: "Dictate message", else: "Converse"}
              aria-pressed={if mode.id == "dictate", do: "false"}
              aria-disabled={to_string(!mode.available)} aria-describedby={if !mode.available, do: "#{@id}-#{mode.id}-reason"}>
              {mode.label}
              <span :if={!mode.available} id={"#{@id}-#{mode.id}-reason"}>{mode.reason}</span>
            </button>
            <a :if={Enum.any?(@modes, & &1.setup)} href="https://aiur.team/docs/apis/elevenlabs#configure-the-key" target="_blank" rel="noopener">Set up voice input</a>
          </div>
        </div>
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
        <details class="agent-voice-settings">
          <summary aria-label="Microphone settings">Settings</summary>
          <label class="agent-voice-device-label">
            <span>Browser microphone</span>
            <select data-voice-device aria-label="Browser microphone">
              <option value="">Default microphone</option>
            </select>
          </label>
        </details>
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
        {if @dictate.available, do: @status_copy, else: @dictate.reason}
      </p>
      <.delivery_status delivery={@delivery} />
    </div>
    """
  end

  attr(:delivery, :map, default: nil)
  @spec delivery_status(map()) :: Phoenix.LiveView.Rendered.t()
  def delivery_status(assigns) do
    ~H"""
    <p :if={@delivery} class="agent-voice-delivery" role="status" aria-live="polite" data-voice-delivery
      data-voice-state={if accepted?(@delivery), do: "sent"} data-delivery-state={@delivery[:state] || :unknown}>
      {delivery_copy(@delivery)}
    </p>
    """
  end

  defp accepted?(%{state: state}), do: state in [:accepted, :held_async, :waiting_turn_end, :harness_queued, :in_context, :read]
  defp accepted?(_delivery), do: false

  defp delivery_copy(%{copy: copy}) when is_binary(copy), do: copy
  defp delivery_copy(%{state: state}) when state in [:accepted, :held_async, :waiting_turn_end], do: "Sent — waiting for the agent"
  defp delivery_copy(%{state: :harness_queued}), do: "Delivered to the agent"
  defp delivery_copy(%{state: state}) when state in [:in_context, :read], do: "The agent has it"
  defp delivery_copy(%{state: :failed}), do: "Send failed. Check the log before you send again."
  defp delivery_copy(%{state: :outcome_unknown}), do: AgentLogModal.format_error({:outcome_unknown, %{}})
  defp delivery_copy(_unknown), do: "Delivery outcome unknown. Check the log before you send again."

  defp mode({id, label, capability}, capabilities) do
    entry = Map.get(capabilities, capability, %{})
    %{id: id, label: label, available: to_string(entry[:state]) in ["available", "degraded"], setup: to_string(entry[:reason]) == "not_configured", reason: reason(entry[:reason], id)}
  end

  defp reason(reason, _id) when reason in [:not_installed, "not_installed"], do: "Voice input isn't installed in this Aiur. Typed messages work as usual."
  defp reason(reason, _id) when reason in [:not_configured, "not_configured"], do: "Voice input is not configured."
  defp reason(reason, _id) when reason in [:disabled, "disabled"], do: "Voice input is disabled."
  defp reason(_reason, "converse"), do: "Converse is not available in this Aiur."
  defp reason(_reason, _id), do: "Voice input availability is unknown."
end
