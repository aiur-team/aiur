defmodule AiurWeb.OperatorControlCenter.AgentLogModal do
  @moduledoc false

  use Phoenix.Component

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  attr(:modal, :map, default: nil)
  attr(:writable, :boolean, required: true)
  attr(:drafts, :map, required: true)
  attr(:errors, :map, required: true)

  @spec agent_log_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_log_modal(assigns) do
    assigns = assign(assigns, :composer_writable, assigns.writable and writable_target?(assigns.modal))

    ~H"""
    <div :if={@modal} class="modal-backdrop agent-log-backdrop">
      <section class="modal-panel agent-log-modal" role="dialog" aria-modal="true" aria-labelledby="agent-log-title" phx-click-away="close-agent-log">
        <header class="modal-header">
          <div>
            <p class="section-eyebrow">Logs</p>
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

        <div id={"agent-log-panel-#{@modal.target_key}"} class="chat-log-panel" phx-hook="AgentLogPanel">
          <div :for={message <- @modal.messages} class={log_message_class(message)}>
            <div class="log-message-header"><span>{message.title}</span><span class="mono">{message.timestamp}</span></div>
            <div class="log-message-body">{message.body}</div>
          </div>
        </div>

        <form :if={@composer_writable} class="agent-chat-composer" phx-change="composer-change" phx-submit="send-operator-message">
          <p :if={error = @errors[@modal.target_key]} class="agent-chat-error">{error}</p>
          <textarea
            class="agent-chat-textarea"
            name="message"
            rows="2"
            placeholder="Message agent…"
            aria-label="Message agent"
            enterkeyhint="send"
          >{@drafts[@modal.target_key] || ""}</textarea>
          <div class="agent-chat-actions">
            <button class="btn danger" type="button" phx-click="pause-agent">Pause</button>
            <button class="btn" type="submit">Send</button>
          </div>
        </form>

        <p :if={!@writable} class="agent-chat-readonly">Read-only dashboard — use the TUI to message or pause this agent.</p>
        <p :if={@writable and !@composer_writable} class="agent-chat-readonly">
          Agent actions are unavailable because this display identifier is not a unique writable target.
        </p>
      </section>
    </div>
    """
  end

  @spec find_running_entry(map(), String.t() | TrackerIdentity.t()) :: map() | nil
  def find_running_entry(%{fleet: %{running: running}}, %TrackerIdentity{} = identity) when is_list(running) do
    key = TrackerIdentity.github_key(identity)

    Enum.find(running, fn entry ->
      not is_nil(key) and key == TrackerIdentity.github_key(Map.get(entry, :tracker_identity))
    end)
  end

  def find_running_entry(%{fleet: %{running: running}}, issue_identifier)
      when is_list(running) and is_binary(issue_identifier) do
    Enum.find(running, &(to_string(&1.issue_identifier) == issue_identifier))
  end

  def find_running_entry(_payload, _issue_identifier), do: nil

  @spec build(map() | nil, map() | nil) :: map()
  def build(entry, payload \\ nil)

  def build(nil, _payload) do
    %{
      issue_identifier: "n/a",
      tracker_identity: nil,
      target_key: "unavailable",
      writable_target?: false,
      path: nil,
      messages: [%{role: "system", title: "Session", timestamp: "n/a", body: "No running session found for this issue."}]
    }
  end

  def build(entry, payload) do
    %{path: path, messages: messages} = read_agent_log(entry)
    identity = Map.get(entry, :tracker_identity)

    %{
      issue_identifier: entry.issue_identifier,
      tracker_identity: identity,
      target_key: target_key(identity, entry.issue_identifier),
      writable_target?: unique_identifier?(payload, entry.issue_identifier),
      path: path,
      messages: messages
    }
  end

  @spec refresh(map() | nil, map()) :: map() | nil
  def refresh(nil, _payload), do: nil

  def refresh(%{tracker_identity: %TrackerIdentity{} = identity} = modal, payload) do
    case find_running_entry(payload, identity) do
      nil -> modal |> Map.put(:writable_target?, false) |> refresh_from_path()
      entry -> build(entry, payload)
    end
  end

  def refresh(%{issue_identifier: issue_identifier} = modal, payload) do
    case find_running_entry(payload, to_string(issue_identifier)) do
      nil -> modal |> Map.put(:writable_target?, false) |> refresh_from_path()
      entry -> build(entry, payload)
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
  def format_error(:ambiguous_identifier), do: "Agent actions require a unique typed target."
  def format_error(:globally_paused), do: "Aiur is globally paused; per-ticket control has no effect. Resume Aiur globally first."
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
  defp writable_target?(%{writable_target?: true}), do: true
  defp writable_target?(_modal), do: false

  defp target_key(%TrackerIdentity{} = identity, issue_identifier) do
    UnitsPresenter.row_token(%{identity: identity}) || to_string(issue_identifier)
  end

  defp target_key(_identity, issue_identifier), do: to_string(issue_identifier)

  defp unique_identifier?(nil, _identifier), do: true

  defp unique_identifier?(%{fleet: %{running: running}}, identifier) when is_list(running) do
    Enum.count(running, &(to_string(Map.get(&1, :issue_identifier)) == to_string(identifier))) == 1
  end

  defp unique_identifier?(_payload, _identifier), do: false
  defp log_message_class(%{role: role}), do: "log-message log-message-#{role}"
end
