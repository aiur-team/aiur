defmodule AiurWeb.OperatorControlCenter.AgentLogModal do
  @moduledoc false

  use Phoenix.Component

  attr(:modal, :map, default: nil)
  attr(:writable, :boolean, required: true)
  attr(:drafts, :map, required: true)
  attr(:errors, :map, required: true)

  @spec agent_log_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_log_modal(assigns) do
    ~H"""
    <div :if={@modal} class="modal-backdrop agent-log-backdrop">
      <section class="modal-panel agent-log-modal" role="dialog" aria-modal="true" aria-labelledby="agent-log-title" phx-click-away="close-agent-log">
        <header class="modal-header">
          <div>
            <p class="section-eyebrow">Agent log</p>
            <h2 id="agent-log-title">{@modal.issue_identifier}</h2>
          </div>
          <div class="modal-actions">
            <button type="button" class="tool-btn live-button" data-agent-log-live data-live="true" aria-pressed="true">
              <span class="status-badge-dot"></span>Live
            </button>
            <button type="button" class="tool-btn" phx-click="close-agent-log">Close</button>
          </div>
        </header>

        <p class="modal-meta mono">{@modal.path || "No local log path"}</p>

        <div id={"agent-log-panel-#{@modal.issue_identifier}"} class="chat-log-panel" phx-hook="AgentLogPanel">
          <div :for={message <- @modal.messages} class={log_message_class(message)}>
            <div class="log-message-header"><span>{message.title}</span><span class="mono">{message.timestamp}</span></div>
            <div class="log-message-body">{message.body}</div>
          </div>
        </div>

        <form :if={@writable} class="agent-chat-composer" phx-change="composer-change" phx-submit="send-operator-message">
          <p :if={error = @errors[@modal.issue_identifier]} class="agent-chat-error">{error}</p>
          <textarea
            class="agent-chat-textarea"
            name="message"
            rows="2"
            placeholder="Message agent…"
            aria-label="Message agent"
            enterkeyhint="send"
          >{@drafts[@modal.issue_identifier] || ""}</textarea>
          <div class="agent-chat-actions">
            <button class="btn danger" type="button" phx-click="pause-agent">Pause</button>
            <button class="btn" type="submit">Send</button>
          </div>
        </form>

        <p :if={!@writable} class="agent-chat-readonly">Read-only dashboard — use the TUI to message or pause this agent.</p>
      </section>
    </div>
    """
  end

  @spec find_running_entry(map(), String.t()) :: map() | nil
  def find_running_entry(%{fleet: %{running: running}}, issue_identifier) when is_list(running) do
    Enum.find(running, &(to_string(&1.issue_identifier) == issue_identifier))
  end

  def find_running_entry(_payload, _issue_identifier), do: nil

  @spec build(map() | nil) :: map()
  def build(nil) do
    %{
      issue_identifier: "n/a",
      path: nil,
      messages: [%{role: "system", title: "Session", timestamp: "n/a", body: "No running session found for this issue."}]
    }
  end

  def build(entry) do
    %{path: path, messages: messages} = read_agent_log(entry)
    %{issue_identifier: entry.issue_identifier, path: path, messages: messages}
  end

  @spec refresh(map() | nil, map()) :: map() | nil
  def refresh(nil, _payload), do: nil

  def refresh(%{issue_identifier: issue_identifier} = modal, payload) do
    case find_running_entry(payload, to_string(issue_identifier)) do
      nil -> refresh_from_path(modal)
      entry -> build(entry)
    end
  end

  def refresh(modal, _payload), do: modal

  @spec format_error(term()) :: String.t()
  def format_error(:no_running_agent), do: "Agent is no longer running."
  def format_error(:empty_message), do: "Message is empty."
  def format_error(:message_too_long), do: "Message is too long."
  def format_error(:interrupt_not_supported), do: "Interrupt is not available right now."
  def format_error(:timeout), do: "Send timed out."
  def format_error(:unavailable), do: "Orchestrator unavailable."
  def format_error(reason), do: inspect(reason)

  defp refresh_from_path(%{path: path} = modal) when is_binary(path) do
    %{modal | messages: path |> Aiur.AgentLog.read() |> Aiur.AgentLog.parse()}
  end

  defp refresh_from_path(modal), do: modal

  defp read_agent_log(%{workspace_path: workspace_path}) when is_binary(workspace_path) do
    Aiur.AgentLog.read_workspace(workspace_path)
  end

  defp read_agent_log(entry) do
    path = agent_log_path(entry)
    %{path: path, messages: path |> Aiur.AgentLog.read() |> Aiur.AgentLog.parse()}
  end

  defp agent_log_path(%{workspace_path: workspace_path}), do: Aiur.AgentLog.workspace_log_path(workspace_path)
  defp agent_log_path(_entry), do: nil
  defp log_message_class(%{role: role}), do: "log-message log-message-#{role}"
end
