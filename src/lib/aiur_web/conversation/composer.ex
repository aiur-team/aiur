defmodule AiurWeb.Conversation.Composer do
  @moduledoc "Worker conversation message form and local delivery observations."
  use Phoenix.Component

  attr(:writable, :boolean, required: true)
  attr(:target, :any, required: true)
  attr(:draft, :string, required: true)
  attr(:overlay, :map, required: true)
  attr(:listener, :any, required: true)

  @spec composer(map()) :: Phoenix.LiveView.Rendered.t()
  def composer(assigns) do
    ~H"""
    <section id="conversation-compose" aria-label="Send a message">
      <p :if={!@writable}>Read-only dashboard — messages cannot be sent.</p>
      <%= if @writable && @target do %>
        <p class="conversation-mode" role="status">
          {mode_label(@listener)}
          <span :if={is_map(@listener) && @listener[:effective_reason]}> · {inspect(@listener[:effective_reason])}</span>
          <span :if={is_map(@listener) && @listener[:routing] == :legacy}> · Legacy routing</span>
        </p>
        <form id="conversation-composer" phx-submit="send" phx-change="draft">
          <label for="conversation-text">Message to agent</label>
          <textarea id="conversation-text" name="text" rows="3" required>{@draft}</textarea>
          <button type="submit" phx-disable-with="Sending…">Send message</button>
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

  defp mode_label(%{effective: :sync}), do: "Sync · next turn"
  defp mode_label(%{effective: :steer}), do: "Steer · interrupts"
  defp mode_label(%{effective: :async}), do: "Async · on demand"
  defp mode_label(_), do: "mode unknown"
  defp state_label(:accepted, _), do: "Accepted; awaiting journal entry"
  defp state_label(:queued, %{effective: :sync}), do: "Queued for next boundary"
  defp state_label(:queued, _), do: "Queued by the harness; awaiting journal entry"
  defp state_label(:held_async, _), do: "Saved; the agent reads it when it chooses"
  defp state_label(:failed, _), do: "Failed; retry when ready"
  defp state_label(:unknown, _), do: "Outcome unknown; check the agent before retrying"
end
