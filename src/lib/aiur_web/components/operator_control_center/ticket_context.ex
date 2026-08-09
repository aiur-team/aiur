defmodule AiurWeb.OperatorControlCenter.TicketContext do
  @moduledoc false

  use Phoenix.Component

  alias Aiur.OpaqueIdentifier
  alias AiurWeb.BuildOrder.TicketContextPresenter

  attr(:id, :string, required: true)
  attr(:context, :map, required: true)
  attr(:mode, :atom, default: :dialog)
  attr(:close_event, :any, default: nil)
  attr(:fallback_focus_id, :string, default: nil)
  attr(:focus_key, :string, default: nil)
  attr(:origin_id, :string, default: nil)
  slot(:extension)

  @spec ticket_context(map()) :: Phoenix.LiveView.Rendered.t()
  def ticket_context(assigns) do
    context = TicketContextPresenter.normalize_view(assigns.context)
    dialog? = assigns.mode == :dialog and valid_close_event?(assigns.close_event)
    close_event = if(dialog? and valid_close_event?(assigns.close_event), do: assigns.close_event)
    fallback_focus_id = safe_opaque(assigns.fallback_focus_id)
    focus_key = safe_opaque(assigns.focus_key)
    origin_id = safe_opaque(assigns.origin_id)

    assigns =
      assigns
      |> assign(:context, context)
      |> assign(:dialog?, dialog?)
      |> assign(:close_event, close_event)
      |> assign(:fallback_focus_id, fallback_focus_id)
      |> assign(:focus_key, focus_key)
      |> assign(:origin_id, origin_id)
      |> assign(:heading_id, "#{assigns.id}-title")
      |> assign(:capabilities, context.capabilities)
      |> assign(:progress_message, progress_message(context.progress))

    ~H"""
    <div :if={@dialog?} class="modal-backdrop ticket-context-backdrop">
      <section
        id={@id}
        class="modal-panel ticket-context-panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby={@heading_id}
        phx-hook="TicketContextDialog"
        data-close-event={@close_event}
        data-focus-fallback-id={@fallback_focus_id}
        data-focus-key={@focus_key}
        data-origin-id={@origin_id}
      >
        <.context_content
          context={@context}
          capabilities={@capabilities}
          heading_id={@heading_id}
          close_event={@close_event}
          progress_message={@progress_message}
          extension={@extension}
        />
      </section>
    </div>

    <section :if={!@dialog?} id={@id} class="section-card ticket-context-region" role="region" aria-labelledby={@heading_id}>
      <.context_content
        context={@context}
        capabilities={@capabilities}
        heading_id={@heading_id}
        close_event={nil}
        progress_message={@progress_message}
        extension={@extension}
      />
    </section>
    """
  end

  attr(:context, :map, required: true)
  attr(:capabilities, :list, required: true)
  attr(:heading_id, :string, required: true)
  attr(:close_event, :any, default: nil)
  attr(:progress_message, :string, required: true)
  attr(:extension, :list, default: [])

  defp context_content(assigns) do
    ~H"""
    <header class="modal-header ticket-context-header">
      <div>
        <p class="section-eyebrow">Ticket context</p>
        <p class="ticket-context-repository mono">{@context.repository}<span :if={@context.identifier}> · #{@context.identifier}</span></p>
        <h2 id={@heading_id} tabindex="-1" data-dialog-heading data-ticket-context-focus="heading">{@context.title}</h2>
      </div>
      <button :if={@close_event} type="button" class="tool-btn" phx-click={@close_event} data-ticket-context-focus="close">Close</button>
    </header>

    <div :if={available_capabilities(@capabilities) != []} class="ticket-context-ctas">
      <a
        :for={capability <- available_capabilities(@capabilities)}
        class="btn sm ticket-context-cta"
        href={capability.href}
        target={if(capability.external?, do: "_blank")}
        rel={if(capability.external?, do: "noopener noreferrer")}
        data-ticket-context-focus={capability_focus_key(capability)}
      >{cta_label(capability)}<span :if={capability.external?} aria-hidden="true"> ↗</span></a>
    </div>

    <p :if={@context.description} class="ticket-context-description">{@context.description}</p>

    <section
      :if={dependencies?(@context.dependencies)}
      class="ticket-context-dependencies"
      aria-labelledby={"#{@heading_id}-dependencies"}
    >
      <h3 id={"#{@heading_id}-dependencies"}>Dependencies</h3>
      <%!-- Follow-up (#1270): tags are non-clickable — the OCC ticket-context data path does
      not yet carry linked-ticket tokens. Mirror the prototype's openTicketModal goto wiring
      once the build-order graph is plumbed to this component. --%>
      <div :if={@context.dependencies.blocked_by != []} class="ticket-context-dep-group">
        <span class="ticket-context-dep-label">Blocked by</span>
        <span :for={dep <- @context.dependencies.blocked_by} class="ticket-context-dep-tag">#{dep.identifier}<span :if={dep.title}> · {dep.title}</span></span>
      </div>
      <div :if={@context.dependencies.blocking != []} class="ticket-context-dep-group">
        <span class="ticket-context-dep-label">Blocking</span>
        <span :for={dep <- @context.dependencies.blocking} class="ticket-context-dep-tag">#{dep.identifier}<span :if={dep.title}> · {dep.title}</span></span>
      </div>
    </section>

    <div :if={@extension != []} class="ticket-context-extension">{render_slot(@extension)}</div>

    <div class="ticket-context-grid">
      <section class="detail-block" aria-labelledby={"#{@heading_id}-facts"}>
        <h3 id={"#{@heading_id}-facts"}>Ticket facts</h3>
        <dl class="metadata-list ticket-context-metadata">
          <div><dt>State</dt><dd>{lifecycle_label(@context.lifecycle)}</dd></div>
          <div><dt>Progress</dt><dd>{@progress_message}</dd></div>
          <div><dt>Last activity</dt><dd><.timestamp value={last_activity_at(@context)} /></dd></div>
          <div><dt>Dependencies</dt><dd>{dependency_count(@context.dependencies)}</dd></div>
        </dl>
      </section>

      <section class="detail-block" aria-labelledby={"#{@heading_id}-activity"}>
        <h3 id={"#{@heading_id}-activity"}>Progress</h3>
        <p class="ticket-context-progress">{@progress_message}</p>
        <meter :if={is_integer(@context.progress.percent)} min="0" max="100" value={@context.progress.percent}>{@context.progress.percent}%</meter>
      </section>
    </div>

    <section class="ticket-context-logs-section" aria-labelledby={"#{@heading_id}-logs"}>
      <header class="section-header compact">
        <div>
          <p class="section-eyebrow">Bounded activity</p>
          <h3 id={"#{@heading_id}-logs"}>Logs</h3>
        </div>
      </header>
      <p :if={@context.logs.entries == []} class="empty-state compact">No safe Log entries are available.</p>
      <p :if={@context.logs.truncated?} class="ticket-context-status" role="status">Logs are truncated to the newest safe entries.</p>
      <div :if={@context.logs.entries != []} class="ticket-context-logs-wrap">
        <table class="ticket-context-logs">
          <thead><tr><th>Activity</th><th>Detail</th><th>When</th></tr></thead>
          <tbody>
            <tr :for={entry <- @context.logs.entries}>
              <td>
                <details>
                  <summary><strong>{entry.label}</strong></summary>
                  <dl>
                    <div><dt>Event</dt><dd>{state_label(entry.kind)}</dd></div>
                    <div><dt>Source</dt><dd>{state_label(entry.source)}</dd></div>
                    <div><dt>Observed</dt><dd><.timestamp value={entry.observed_at} /></dd></div>
                  </dl>
                </details>
              </td>
              <td>{activity_detail(entry)}</td>
              <td><.timestamp value={entry.occurred_at || entry.observed_at} /></td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <nav
      :if={unavailable_capabilities(@capabilities) != []}
      class="ticket-context-capabilities"
      aria-label="Unavailable ticket destinations"
    >
      <h3>Unavailable destinations</h3>
      <div class="link-list">
        <div :for={capability <- unavailable_capabilities(@capabilities)} class="ticket-context-capability">
          <span class="link-pill unavailable" aria-disabled="true">{capability.label}</span>
          <p class="ticket-context-capability-reason">{capability.reason}</p>
        </div>
      </div>
    </nav>
    """
  end

  attr(:value, :any, default: nil)

  defp timestamp(assigns) do
    ~H"""
    <time :if={is_struct(@value, DateTime)} datetime={DateTime.to_iso8601(@value)}>{relative(@value)}</time>
    <span :if={!is_struct(@value, DateTime)}>Unknown</span>
    """
  end

  defp relative(%DateTime{} = value) do
    diff = DateTime.diff(DateTime.utc_now(), value, :second)

    cond do
      diff <= 60 -> "just now"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp available_capabilities(capabilities), do: Enum.filter(capabilities, & &1.available?)
  defp unavailable_capabilities(capabilities), do: Enum.reject(capabilities, & &1.available?)

  defp cta_label(%{kind: :github, variant: :pull_request}), do: "Open pull request"
  defp cta_label(%{kind: :github}), do: "Open in GitHub"
  defp cta_label(%{kind: :document}), do: "Open planning doc"
  defp cta_label(%{kind: :chat}), do: "Read chat"
  defp cta_label(%{kind: :commands}), do: "View command"
  defp cta_label(capability), do: capability.label

  defp dependencies?(%{blocked_by: blocked_by, blocking: blocking}),
    do: blocked_by != [] or blocking != []

  defp dependencies?(_dependencies), do: false

  defp progress_message(%{status: :known, percent: percent, source: source}) when is_integer(percent),
    do: "#{percent}% · #{state_label(source)}"

  defp progress_message(_progress), do: "Progress is unknown."

  defp activity_detail(%{details: %{percent: percent}}), do: "#{percent}% complete"

  defp activity_detail(%{details: %{severity: severity, needs_attention: true}}),
    do: "#{state_label(severity)} · needs attention"

  defp activity_detail(%{details: %{severity: severity}}), do: state_label(severity)
  defp activity_detail(%{kind: kind}), do: state_label(kind)

  defp last_activity_at(%{logs: %{entries: [entry | _]}}), do: entry.occurred_at || entry.observed_at
  defp last_activity_at(%{progress: progress}), do: progress.occurred_at || progress.observed_at
  defp last_activity_at(_context), do: nil

  defp dependency_count(%{blocked_by: blocked_by, blocking: blocking}) do
    count = length(blocked_by) + length(blocking)
    if count == 1, do: "1 linked ticket", else: "#{count} linked tickets"
  end

  defp dependency_count(_dependencies), do: "0 linked tickets"

  defp lifecycle_label(%{state: state, reason: reason}), do: "#{state_label(state)} — #{state_label(reason)}"
  defp lifecycle_label(_lifecycle), do: "Unknown"
  defp state_label(nil), do: "Unknown"
  defp state_label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp capability_focus_key(capability) do
    variant = Map.get(capability, :variant) || :default
    "capability-#{Map.get(capability, :kind)}-#{variant}"
  end

  defp valid_close_event?(value) when is_binary(value), do: Regex.match?(~r/^[a-z][a-z0-9-]{0,63}$/, value)
  defp valid_close_event?(_value), do: false
  defp safe_opaque(value), do: OpaqueIdentifier.normalize(value)
end
