defmodule AiurWeb.OperatorControlCenter.ConversationDrawer do
  @moduledoc """
  Accessible conversation drawer for the Units Chat destination.

  Renders a normalized `Presenter` view as a modal side drawer (wide screens) or
  full-width dialog (narrow screens). The component performs no I/O and holds no
  message/pause/capacity mutation handler: it is a pure projection of one pinned
  DASH-026 generation. Focus trap, Escape/close, focus return, scroll
  containment, auto-follow, and the jump-to-latest control are managed by the
  `ConversationDrawer` client hook. Its voice controller keeps dictation in the
  ordinary message textarea until the operator submits it, and runs explicit
  push-to-talk turns in conversation mode.
  """

  use Phoenix.Component

  alias Aiur.OpaqueIdentifier

  attr(:id, :string, required: true)
  attr(:view, :map, default: nil)
  attr(:close_event, :any, default: nil)
  attr(:fallback_focus_id, :string, default: nil)
  attr(:origin_id, :string, default: nil)
  attr(:composer, :map, default: nil)
  attr(:writable, :boolean, default: false)
  attr(:drafts, :map, default: %{})
  attr(:errors, :map, default: %{})

  @spec conversation_drawer(map()) :: Phoenix.LiveView.Rendered.t()
  def conversation_drawer(%{view: nil} = assigns), do: ~H""

  def conversation_drawer(assigns) do
    close_event = if valid_close_event?(assigns.close_event), do: assigns.close_event

    assigns =
      assigns
      |> assign(:close_event, close_event)
      |> assign(:fallback_focus_id, safe_opaque(assigns.fallback_focus_id))
      |> assign(:origin_id, safe_opaque(assigns.origin_id))
      |> assign(:heading_id, "#{assigns.id}-title")
      |> assign(:composer_writable, composer_writable?(assigns.composer) and assigns.writable)
      |> assign(:composer_key, composer_key(assigns.composer))

    ~H"""
    <div class="modal-backdrop conversation-drawer-backdrop">
      <section
        id={@id}
        class="modal-panel conversation-drawer-panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby={@heading_id}
        phx-hook="ConversationDrawer"
        data-close-event={@close_event}
        data-focus-fallback-id={@fallback_focus_id}
        data-origin-id={@origin_id}
      >
        <header class="modal-header conversation-drawer-header">
          <div>
            <p class="section-eyebrow">Conversation</p>
            <p class="conversation-drawer-identity mono">{@view.heading.identity_label}</p>
            <h2 id={@heading_id} tabindex="-1" data-dialog-heading data-conversation-focus="heading">
              {@view.heading.title}
            </h2>
          </div>
          <div class="modal-actions">
            <button
              :if={@close_event}
              type="button"
              class="tool-btn conversation-drawer-close"
              phx-click={@close_event}
              data-conversation-focus="close"
            >Close</button>
          </div>
        </header>

        <div class="conversation-drawer-summary">
          <p class="conversation-drawer-notice">
            {if(@composer_writable,
              do: "Live conversation mirror. Messages you send here are delivered to this agent.",
              else: @view.participation_notice
            )}
          </p>
          <ul class="conversation-drawer-states" aria-label="Conversation state">
            <li><span class="conversation-state-chip" data-state={@view.state}>{@view.state_label}</span></li>
            <li><span class="conversation-state-chip is-meta">Health: {@view.health_label}</span></li>
            <li><span class="conversation-state-chip is-meta">Freshness: {@view.freshness_label}</span></li>
          </ul>
          <p class="conversation-drawer-detail" role="status" aria-live="polite">{@view.state_detail}</p>
        </div>

        <dl class="conversation-drawer-metadata">
          <div :for={item <- @view.metadata}>
            <dt>{item.label}</dt>
            <dd>{item.value}</dd>
          </div>
        </dl>

        <div class="conversation-drawer-body">
          <p :if={@view.truncation_note} class="conversation-drawer-truncation" role="status">
            {@view.truncation_note}
          </p>
          <div
            id={"#{@id}-scroll"}
            class="conversation-drawer-scroll chat-log-panel"
            data-conversation-scroll
            data-live={to_string(@view.live?)}
            tabindex="0"
            role="log"
            aria-label="Conversation messages"
            aria-live={if(@view.live?, do: "polite", else: "off")}
          >
            <p :if={@view.empty?} class="empty-state compact conversation-drawer-empty">
              {empty_message(@view.state)}
            </p>
            <ol :if={not @view.empty?} class="conversation-drawer-messages">
              <li
                :for={message <- @view.messages}
                id={"#{@id}-message-#{message.id}"}
                class={"conversation-message conversation-message-#{message.role}"}
                data-message-complete={to_string(message.complete?)}
              >
                <article>
                  <header class="conversation-message-header">
                    <span class="conversation-message-role">{message.role_label}</span>
                    <span :if={message.title != message.role_label} class="conversation-message-title">
                      {message.title}
                    </span>
                    <.timestamp value={message.occurred_at} class="conversation-message-time mono" />
                  </header>
                  <p class="conversation-message-body">{message.body}</p>
                </article>
              </li>
            </ol>
            <section :if={@view.log} class="conversation-drawer-log" aria-label="Agent log">
              <h3 class="conversation-drawer-log-heading">Agent log</h3>
              <ol class="conversation-drawer-log-entries">
                <li
                  :for={entry <- @view.log}
                  id={"#{@id}-log-#{entry.id}"}
                  class={"conversation-message conversation-log-entry conversation-log-#{entry.role}"}
                >
                  <article>
                    <header class="conversation-message-header">
                      <span class="conversation-message-role">{entry.role_label}</span>
                      <span :if={entry.title != entry.role_label} class="conversation-message-title">
                        {entry.title}
                      </span>
                      <span class="conversation-message-time mono">{entry.timestamp}</span>
                    </header>
                    <p class="conversation-message-body">{entry.body}</p>
                  </article>
                </li>
              </ol>
            </section>
          </div>
          <button type="button" class="btn conversation-drawer-jump" data-conversation-jump hidden>
            Jump to latest
          </button>
        </div>

        <footer class="conversation-drawer-footer">
          <dl class="conversation-drawer-provenance">
            <div><dt>Last observation</dt><dd><.timestamp value={@view.observed_at} /></dd></div>
            <div><dt>Messages</dt><dd class="mono num">{@view.message_count}</dd></div>
          </dl>
          <form
            :if={@composer_writable}
            class="agent-chat-composer"
            phx-change="composer-change"
            phx-submit="send-operator-message"
            data-voice-composer
          >
            <p :if={error = @errors[@composer_key]} class="agent-chat-error">{error}</p>
            <textarea
              class="agent-chat-textarea"
              name="message"
              rows="2"
              placeholder="Message agent…"
              aria-label="Message agent"
              enterkeyhint="send"
              data-voice-input
            >{@drafts[@composer_key] || ""}</textarea>
            <div class="agent-voice-tools">
              <div class="agent-voice-controls">
                <button
                  class="tool-btn agent-voice-button"
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
                  class="tool-btn agent-voice-button"
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
            <div class="agent-chat-actions">
              <button class="btn danger" type="button" phx-click="pause-agent">Pause</button>
              <button class="btn" type="submit" data-voice-send>Send</button>
            </div>
          </form>
          <p :if={!@writable} class="agent-chat-readonly">Read-only dashboard — use the TUI to message or pause this agent.</p>
          <p :if={@writable and !@composer_writable} class="agent-chat-readonly">
            Agent actions are unavailable because this display identifier is not a unique writable target.
          </p>
        </footer>
      </section>
    </div>
    """
  end

  defp composer_writable?(%{writable_target?: true}), do: true
  defp composer_writable?(_composer), do: false

  defp composer_key(%{target_key: key}) when is_binary(key), do: key
  defp composer_key(_composer), do: "unavailable"

  attr(:value, :any, default: nil)
  attr(:class, :string, default: nil)

  defp timestamp(assigns) do
    ~H"""
    <time :if={is_struct(@value, DateTime)} class={@class} datetime={DateTime.to_iso8601(@value)}>
      {DateTime.to_iso8601(@value)}
    </time>
    <span :if={!is_struct(@value, DateTime)} class={@class}>Time unknown</span>
    """
  end

  defp empty_message(:known_empty), do: "No conversation has been recorded for this worker yet."
  defp empty_message(:unavailable), do: "No conversation is available from the source right now."
  defp empty_message(:restart_unknown), do: "No retained conversation is available after the restart."
  defp empty_message(_state), do: "No messages are available to display."

  defp valid_close_event?(value) when is_binary(value),
    do: Regex.match?(~r/^[a-z][a-z0-9-]{0,63}$/, value)

  defp valid_close_event?(_value), do: false

  defp safe_opaque(value), do: OpaqueIdentifier.normalize(value)
end
