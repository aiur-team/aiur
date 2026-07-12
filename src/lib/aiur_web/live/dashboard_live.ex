defmodule AiurWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Aiur.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.{AgentChat, Alerts}
  alias AiurWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:agent_log_modal, nil)
      |> assign(:drafts, %{})
      |> assign(:chat_errors, %{})
      |> assign(:writable, dashboard_writable?())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    payload = load_payload()

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:now, DateTime.utc_now())
     |> assign(:agent_log_modal, refresh_agent_log_modal(socket.assigns.agent_log_modal, payload))}
  end

  @impl true
  def handle_event("show-agent-log", %{"issue" => issue_identifier}, socket) do
    entry = find_running_entry(socket.assigns.payload, issue_identifier)
    maybe_emit_chat_open(entry)
    {:noreply, assign(socket, :agent_log_modal, agent_log_modal(entry))}
  end

  @impl true
  def handle_event("close-agent-log", _params, socket) do
    maybe_emit_chat_close(socket.assigns.agent_log_modal)
    {:noreply, assign(socket, :agent_log_modal, nil)}
  end

  @impl true
  def handle_event("composer-change", %{"message" => message}, %{assigns: %{writable: true, agent_log_modal: modal}} = socket)
      when is_map(modal) do
    identifier = modal.issue_identifier

    {:noreply,
     socket
     |> assign(:drafts, Map.put(socket.assigns.drafts, identifier, message))
     |> assign(:chat_errors, Map.delete(socket.assigns.chat_errors, identifier))}
  end

  def handle_event("composer-change", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("send-operator-message", %{"message" => message}, %{assigns: %{writable: true, agent_log_modal: modal}} = socket)
      when is_map(modal) do
    identifier = modal.issue_identifier
    text = String.trim(message)

    if text == "" do
      {:noreply, socket}
    else
      case AgentChat.send(identifier, text) do
        {:ok, _request_id} ->
          {:noreply,
           socket
           |> assign(:drafts, Map.delete(socket.assigns.drafts, identifier))
           |> assign(:chat_errors, Map.delete(socket.assigns.chat_errors, identifier))}

        {:error, reason} ->
          {:noreply, assign(socket, :chat_errors, Map.put(socket.assigns.chat_errors, identifier, format_chat_error(reason)))}
      end
    end
  end

  def handle_event("send-operator-message", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("pause-agent", _params, %{assigns: %{writable: true, agent_log_modal: modal}} = socket) when is_map(modal) do
    identifier = modal.issue_identifier

    case AgentChat.pause(identifier) do
      {:ok, _request_id} ->
        {:noreply, assign(socket, :chat_errors, Map.delete(socket.assigns.chat_errors, identifier))}

      {:error, reason} ->
        {:noreply, assign(socket, :chat_errors, Map.put(socket.assigns.chat_errors, identifier, format_chat_error(reason)))}
    end
  end

  def handle_event("pause-agent", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Aiur Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Aiur runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-info">ITS: <%= tracker_kind() %></span>
            <span class="status-badge status-badge-info">Agent: <%= agent_kind() %></span>
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.agent_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.agent_totals.input_tokens) %> / Out <%= format_int(@payload.agent_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total agent runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 9rem;" />
                  <col style="width: 6rem;" />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Waiting</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Agent update</th>
                    <th>CI / Review</th>
                    <th>Decisions</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={entry <- @payload.running}
                    class="clickable-row"
                    phx-click="show-agent-log"
                    phx-value-issue={entry.issue_identifier}
                  >
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a
                          class="issue-link"
                          href={"/api/v1/#{entry.issue_identifier}"}
                          onclick="event.stopPropagation()"
                        >JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <span class={waiting_reason_badge_class(entry.waiting_reason)}>
                        <%= format_waiting_reason(entry.waiting_reason) %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="event.stopPropagation(); navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                          <%= if age = format_stale_age(entry.stale_for_seconds) do %>
                            · <span class="numeric"><%= age %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td class="numeric"><%= format_ci_review(entry.ci, entry.review) %></td>
                    <td class="numeric">
                      <%= if entry.open_decision_count > 0 do %>
                        <span class="state-badge state-badge-warning">❗<%= entry.open_decision_count %></span>
                      <% else %>
                        <span class="muted">—</span>
                      <% end %>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Queued / waiting</h2>
              <p class="section-copy">Tracker-active work with no live agent process right now.</p>
            </div>
          </div>

          <%= if @payload.idle == [] do %>
            <p class="empty-state">No queued or waiting issues.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 620px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Waiting</th>
                    <th>CI / Review</th>
                    <th>Decisions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.idle}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <span class={waiting_reason_badge_class(entry.waiting_reason)}>
                        <%= format_waiting_reason(entry.waiting_reason) %>
                      </span>
                    </td>
                    <td class="numeric"><%= format_ci_review(entry.ci, entry.review) %></td>
                    <td class="numeric">
                      <%= if entry.open_decision_count > 0 do %>
                        <span class="state-badge state-badge-warning">❗<%= entry.open_decision_count %></span>
                      <% else %>
                        <span class="muted">—</span>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 980px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Waiting</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>CI / Review</th>
                    <th>Decisions</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state || "n/a" %>
                      </span>
                    </td>
                    <td>
                      <span class={waiting_reason_badge_class(entry.waiting_reason)}>
                        <%= format_waiting_reason(entry.waiting_reason) %>
                      </span>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td class="numeric"><%= format_ci_review(entry.ci, entry.review) %></td>
                    <td class="numeric">
                      <%= if entry.open_decision_count > 0 do %>
                        <span class="state-badge state-badge-warning">❗<%= entry.open_decision_count %></span>
                      <% else %>
                        <span class="muted">—</span>
                      <% end %>
                    </td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>

      <%= if @agent_log_modal do %>
        <div class="modal-backdrop">
          <section class="modal-panel" phx-click-away="close-agent-log">
            <div class="modal-header">
              <div>
                <p class="eyebrow">Agent log</p>
                <h2 class="modal-title"><%= @agent_log_modal.issue_identifier %></h2>
              </div>
              <div class="modal-actions">
                <button
                  type="button"
                  class="subtle-button live-button"
                  data-agent-log-live
                  data-live="true"
                  aria-pressed="true"
                >
                  <span class="live-button-dot"></span>
                  Live
                </button>
                <button type="button" class="subtle-button" phx-click="close-agent-log">Close</button>
              </div>
            </div>

            <p class="modal-meta mono"><%= @agent_log_modal.path || "No local log path" %></p>

            <div
              id={"agent-log-panel-#{@agent_log_modal.issue_identifier}"}
              class="chat-log-panel"
              phx-hook="AgentLogPanel"
            >
              <div :for={message <- @agent_log_modal.messages} class={log_message_class(message)}>
                <div class="log-message-header">
                  <span><%= message.title %></span>
                  <span class="mono"><%= message.timestamp %></span>
                </div>
                <div class="log-message-body"><%= message.body %></div>
              </div>
            </div>

            <%= if @writable do %>
              <form class="agent-chat-composer" phx-change="composer-change" phx-submit="send-operator-message">
                <%= if error = @chat_errors[@agent_log_modal.issue_identifier] do %>
                  <p class="agent-chat-error"><%= error %></p>
                <% end %>
                <textarea
                  class="agent-chat-textarea"
                  name="message"
                  rows="2"
                  placeholder="Message agent..."
                  aria-label="Message agent"
                  enterkeyhint="send"
                ><%= @drafts[@agent_log_modal.issue_identifier] || "" %></textarea>
                <div class="agent-chat-actions">
                  <button class="agent-chat-pause" type="button" phx-click="pause-agent">Pause</button>
                  <button class="agent-chat-send" type="submit">Send</button>
                </div>
              </form>
            <% else %>
              <p class="agent-chat-readonly">Read-only dashboard — use the TUI to message or pause this agent.</p>
            <% end %>
          </section>
        </div>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || Aiur.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  # Read-only by default until the dashboard parity pass (#371). Fail closed so
  # the browser never exposes write controls when config is unresolved.
  defp dashboard_writable? do
    Endpoint.config(:dashboard_writable) == true
  end

  defp completed_runtime_seconds(payload) do
    payload.agent_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  # Explicit waiting-reason vocabulary (OCC-5) — never "blocked". Reuses the
  # existing badge palette rather than adding new colors.
  defp waiting_reason_badge_class(:active), do: "state-badge state-badge-active"
  defp waiting_reason_badge_class(:unresponsive), do: "state-badge state-badge-danger"
  defp waiting_reason_badge_class(_reason), do: "state-badge state-badge-warning"

  defp format_waiting_reason(:active), do: "active"
  defp format_waiting_reason(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp format_stale_age(seconds) when is_integer(seconds) and seconds >= 0 do
    "#{format_runtime_seconds(seconds)} ago"
  end

  defp format_stale_age(_seconds), do: nil

  defp format_ci_review(nil, review), do: format_review(review)

  defp format_ci_review(%{decision: decision, pr_number: pr_number}, review) do
    pr = if pr_number, do: "PR ##{pr_number}", else: "CI"
    "#{pr} #{decision} · #{format_review(review)}"
  end

  defp format_review(:awaiting), do: "review awaiting"
  defp format_review(_review), do: "review not started"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp tracker_kind, do: Aiur.Config.tracker_kind()
  defp agent_kind, do: Aiur.Config.agent_kind()

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp find_running_entry(%{running: running}, issue_identifier) when is_list(running) do
    Enum.find(running, &(to_string(&1.issue_identifier) == issue_identifier))
  end

  defp find_running_entry(_payload, _issue_identifier), do: nil

  defp agent_log_modal(nil) do
    %{
      issue_identifier: "n/a",
      path: nil,
      messages: [
        %{
          role: "system",
          title: "Session",
          timestamp: "n/a",
          body: "No running session found for this issue."
        }
      ]
    }
  end

  defp agent_log_modal(entry) do
    %{path: path, messages: messages} = read_agent_log(entry)

    %{
      issue_identifier: entry.issue_identifier,
      path: path,
      messages: messages
    }
  end

  defp refresh_agent_log_modal(nil, _payload), do: nil

  defp refresh_agent_log_modal(%{issue_identifier: issue_identifier} = modal, payload) do
    case find_running_entry(payload, to_string(issue_identifier)) do
      nil -> refresh_agent_log_modal_from_path(modal)
      entry -> agent_log_modal(entry)
    end
  end

  defp refresh_agent_log_modal(modal, _payload), do: modal

  defp refresh_agent_log_modal_from_path(%{path: path} = modal) when is_binary(path) do
    %{modal | messages: path |> Aiur.AgentLog.read() |> Aiur.AgentLog.parse()}
  end

  defp refresh_agent_log_modal_from_path(modal), do: modal

  defp agent_log_path(%{workspace_path: workspace_path}) do
    Aiur.AgentLog.workspace_log_path(workspace_path)
  end

  defp agent_log_path(_entry), do: nil

  defp read_agent_log(%{workspace_path: workspace_path}) when is_binary(workspace_path) do
    Aiur.AgentLog.read_workspace(workspace_path)
  end

  defp read_agent_log(entry) do
    path = agent_log_path(entry)
    %{path: path, messages: path |> Aiur.AgentLog.read() |> Aiur.AgentLog.parse()}
  end

  defp log_message_class(%{role: role}), do: "log-message log-message-#{role}"

  defp format_chat_error(:no_running_agent), do: "Agent is no longer running."
  defp format_chat_error(:empty_message), do: "Message is empty."
  defp format_chat_error(:message_too_long), do: "Message is too long."
  defp format_chat_error(:interrupt_not_supported), do: "Interrupt is not available right now."
  defp format_chat_error(:timeout), do: "Send timed out."
  defp format_chat_error(:unavailable), do: "Orchestrator unavailable."
  defp format_chat_error(reason), do: inspect(reason)

  defp maybe_emit_chat_open(%{identifier: identifier, workspace_path: workspace_path}) do
    Alerts.emit_system("ticket.#{identifier}.chat.opened",
      issue: identifier,
      workspace: workspace_path
    )
  end

  defp maybe_emit_chat_open(_entry), do: :ok

  defp maybe_emit_chat_close(%{issue_identifier: identifier, path: path}) do
    workspace =
      case path do
        nil -> nil
        log_path -> log_path |> Path.dirname() |> Path.dirname()
      end

    Alerts.emit_system("ticket.#{identifier}.chat.closed", issue: identifier, workspace: workspace)
  end

  defp maybe_emit_chat_close(_modal), do: :ok
end
