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
      |> assign(:detail_message, detail_message(context.detail.state))
      |> assign(:history_message, history_message(context.history.state))
      |> assign(:progress_message, progress_message(context.progress))
      |> assign(:evidence_message, evidence_message(context.latest_evidence))

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
          detail_message={@detail_message}
          history_message={@history_message}
          progress_message={@progress_message}
          evidence_message={@evidence_message}
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
        detail_message={@detail_message}
        history_message={@history_message}
        progress_message={@progress_message}
        evidence_message={@evidence_message}
        extension={@extension}
      />
    </section>
    """
  end

  attr(:context, :map, required: true)
  attr(:capabilities, :list, required: true)
  attr(:heading_id, :string, required: true)
  attr(:close_event, :any, default: nil)
  attr(:detail_message, :string, required: true)
  attr(:history_message, :string, required: true)
  attr(:progress_message, :string, required: true)
  attr(:evidence_message, :string, required: true)
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

    <p :if={@context.description} class="ticket-context-description">{@context.description}</p>

    <p class="ticket-context-status" role="status" aria-live="polite">{@detail_message} {@history_message}</p>

    <div :if={@extension != []} class="ticket-context-extension">{render_slot(@extension)}</div>

    <div class="ticket-context-grid">
      <section class="detail-block" aria-labelledby={"#{@heading_id}-facts"}>
        <h3 id={"#{@heading_id}-facts"}>Ticket facts</h3>
        <dl class="metadata-list ticket-context-metadata">
          <div><dt>Lifecycle</dt><dd>{lifecycle_label(@context.lifecycle)}</dd></div>
          <div><dt>Detail</dt><dd>{state_label(@context.detail.state)}</dd></div>
          <div><dt>History</dt><dd>{state_label(@context.history.state)}</dd></div>
          <div><dt>History freshness</dt><dd>{state_label(@context.history.freshness)}</dd></div>
          <div><dt>Detail observed</dt><dd><.timestamp value={@context.detail.observed_at} /></dd></div>
          <div><dt>History observed</dt><dd><.timestamp value={@context.history.observed_at} /></dd></div>
        </dl>
      </section>

      <section class="detail-block" aria-labelledby={"#{@heading_id}-activity"}>
        <h3 id={"#{@heading_id}-activity"}>Progress and evidence</h3>
        <p class="ticket-context-progress">{@progress_message}</p>
        <meter :if={is_integer(@context.progress.percent)} min="0" max="100" value={@context.progress.percent}>{@context.progress.percent}%</meter>
        <.activity_timing label="Progress" activity={@context.progress} />
        <p class="ticket-context-evidence">{@evidence_message}</p>
        <.activity_timing label="Evidence" activity={@context.latest_evidence} />
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
      <ol :if={@context.logs.entries != []} class="ticket-context-logs">
        <li :for={entry <- @context.logs.entries}>
          <article>
            <header><strong>{entry.label}</strong><span class="chip mono">{state_label(entry.source)}</span></header>
            <dl>
              <div><dt>Occurred</dt><dd><.timestamp value={entry.occurred_at} /></dd></div>
              <div><dt>Observed</dt><dd><.timestamp value={entry.observed_at} /></dd></div>
            </dl>
          </article>
        </li>
      </ol>
    </section>

    <nav class="ticket-context-capabilities" aria-label="Ticket destinations">
      <h3>Destinations</h3>
      <div class="link-list">
        <div :for={capability <- @capabilities} class="ticket-context-capability">
          <a
            :if={capability.available?}
            class="link-pill"
            href={capability.href}
            target={if(capability.external?, do: "_blank")}
            rel={if(capability.external?, do: "noopener noreferrer")}
            data-ticket-context-focus={capability_focus_key(capability)}
          >{capability.label}<span :if={capability.external?} aria-hidden="true"> ↗</span></a>
          <span :if={!capability.available?} class="link-pill unavailable" aria-disabled="true">{capability.label}</span>
          <p :if={!capability.available?} class="ticket-context-capability-reason">{capability.reason}</p>
        </div>
      </div>
    </nav>
    """
  end

  attr(:value, :any, default: nil)

  defp timestamp(assigns) do
    ~H"""
    <time :if={is_struct(@value, DateTime)} datetime={DateTime.to_iso8601(@value)}>{DateTime.to_iso8601(@value)}</time>
    <span :if={!is_struct(@value, DateTime)}>Unknown</span>
    """
  end

  attr(:label, :string, required: true)
  attr(:activity, :map, required: true)

  defp activity_timing(assigns) do
    provenance = Map.get(assigns.activity, :provenance, %{})
    assigns = assign(assigns, :provenance, provenance)

    ~H"""
    <p class="ticket-context-provenance"><span>{@label} occurred:</span> <.timestamp value={@activity.occurred_at} /></p>
    <p class="ticket-context-provenance"><span>{@label} observed:</span> <.timestamp value={@activity.observed_at} /></p>
    <dl :if={is_map(@provenance) and map_size(@provenance) > 0} class="ticket-context-provenance-list">
      <div :for={{key, value} <- @provenance}>
        <dt>{state_label(key)}</dt>
        <dd>{provenance_value(value)}</dd>
      </div>
    </dl>
    """
  end

  defp detail_message(:available), do: "Ticket detail is current."
  defp detail_message(:stale), do: "Ticket detail is stale."
  defp detail_message(:missing), do: "Ticket detail has not been loaded."
  defp detail_message(_state), do: "Ticket detail is unavailable."

  defp history_message(:available), do: "Ticket history is current."
  defp history_message(:known_empty), do: "No history has been recorded yet."
  defp history_message(:missing_source), do: "Ticket history is not available from its source."
  defp history_message(:restart_unknown), do: "Activity continuity is unknown after restart."
  defp history_message(:stale), do: "Ticket history is stale."
  defp history_message(_state), do: "Ticket history is unavailable."

  defp progress_message(%{status: :known, percent: percent, source: source}) when is_integer(percent),
    do: "#{percent}% · #{state_label(source)}"

  defp progress_message(_progress), do: "Progress is unknown."

  defp evidence_message(%{status: :known, source: %{kind: kind, name: name}}),
    do: "Latest evidence: #{state_label(kind)} / #{name}"

  defp evidence_message(_evidence), do: "Latest evidence is unknown."

  defp lifecycle_label(%{state: state, reason: reason}), do: "#{state_label(state)} — #{state_label(reason)}"
  defp lifecycle_label(_lifecycle), do: "Unknown"
  defp state_label(nil), do: "Unknown"
  defp state_label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp provenance_value(value) when is_integer(value), do: Integer.to_string(value)
  defp provenance_value(value) when is_binary(value), do: value
  defp provenance_value(_value), do: "Unknown"

  defp capability_focus_key(capability) do
    variant = Map.get(capability, :variant) || :default
    "capability-#{Map.get(capability, :kind)}-#{variant}"
  end

  defp valid_close_event?(value) when is_binary(value), do: Regex.match?(~r/^[a-z][a-z0-9-]{0,63}$/, value)
  defp valid_close_event?(_value), do: false
  defp safe_opaque(value), do: OpaqueIdentifier.normalize(value)
end
