defmodule AiurWeb.Conversation.Composer do
  @moduledoc "Shared worker and Executor message form and local delivery observations."
  use Phoenix.Component
  alias Aiur.Conversation.Ref
  alias Aiur.Listener.ModeCopy
  alias AiurWeb.Components.VoiceInput

  attr(:writable, :boolean, required: true)
  attr(:target, :any, required: true)
  attr(:draft, :string, required: true)
  attr(:overlay, :map, required: true)
  attr(:listener, :any, required: true)
  attr(:voice_capabilities, :map, default: %{})
  attr(:instance_id, :string, default: nil)

  @spec composer(map()) :: Phoenix.LiveView.Rendered.t()
  def composer(assigns) do
    executor? = match?(%Ref{subject: :executor}, assigns.target)

    assigns =
      assigns
      |> assign(:executor?, executor?)
      |> assign(:voice_enabled?, executor? && assigns.writable && is_map(assigns.listener) && assigns.listener[:effective] in [:sync, :steer, :async])

    ~H"""
    <section id="conversation-compose" aria-label="Send a message">
      <p :if={!@writable}>Read-only dashboard — messages cannot be sent.</p>
      <%= if @writable && @target do %>
        <p class="conversation-mode" role="status">
          {mode_label(@listener)}
          <span :if={is_map(@listener) && @listener[:effective_reason]}> · {inspect(@listener[:effective_reason])}</span>
          <span :if={is_map(@listener) && @listener[:routing] == :legacy}> · Legacy routing</span>
        </p>
        <form id="conversation-composer" phx-submit="send" phx-change="draft" phx-hook={if @voice_enabled?, do: "VoiceInput"}>
          <label for="conversation-text">{if @executor?, do: "Message to Executor", else: "Message to agent"}</label>
          <textarea id="conversation-text" name="text" rows="3" required data-voice-input={if @voice_enabled?, do: ""}
            disabled={@executor? && !@voice_enabled?}>{@draft}</textarea>
          <VoiceInput.voice_input :if={@voice_enabled?} id="executor-composer-voice" surface="executor_composer"
            target={%{kind: "executor", instance_id: @instance_id || Aiur.Identity.instance_id()}}
            capabilities={@voice_capabilities} legacy_conversation={false} />
          <button type="submit" phx-disable-with="Sending…" data-voice-send={if @voice_enabled?, do: ""}
            disabled={@executor? && !@voice_enabled?}>Send message</button>
        </form>
      <% end %>
      <p :if={@writable && !@target}>Messaging is unavailable for this conversation.</p>
      <ul id="conversation-delivery" aria-live="polite" aria-label="Message delivery">
        <li :for={{id, item} <- Enum.sort_by(@overlay, fn {_id, item} -> item.started_at end)} id={"delivery-#{id}"} data-delivery-state={item.state}>
          <p class="conversation-body">{item.text}</p>
          <p>{state_label(item.state, @listener)}<span :if={item.reason}> · {inspect(item.reason)}</span></p>
        </li>
      </ul>
    </section>
    """
  end

  defp mode_label(%{effective: mode}) when mode in [:steer, :sync, :async, :mute], do: ModeCopy.label(mode)
  defp mode_label(_), do: "mode unknown"
  defp state_label(:accepted, _), do: "Accepted; awaiting journal entry"
  defp state_label(:queued, %{effective: :sync}), do: "Queued for next boundary"
  defp state_label(:queued, _), do: "Queued by the harness; awaiting journal entry"
  defp state_label(:held_async, _), do: "Saved; the agent reads it when it chooses"
  defp state_label(:failed, _), do: "Failed; retry when ready"
  defp state_label(:unknown, _), do: "Outcome unknown; check the agent before retrying"
end
