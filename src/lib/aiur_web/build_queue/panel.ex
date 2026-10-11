defmodule AiurWeb.BuildQueue.Panel do
  @moduledoc "Read-only build queue panel for the Build Order catalog."
  use Phoenix.Component
  alias AiurWeb.BuildQueue.{Copy, Runtime}

  # Inline because dashboard.css is over its size limit. The surface's grid gap
  # spaces these short lines, so browser margins would double it.
  defp flat, do: "margin: 0"
  defp muted, do: "margin: 0; color: var(--muted); font-size: 0.9rem"
  defp heading, do: "margin: 0 0 0.35rem; font-size: 0.95rem"

  attr(:view, :map, default: nil)
  attr(:now, :any, required: true)

  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    assigns = assigns |> assign(:state, state(assigns.view)) |> assign(:attentions, if(assigns.view, do: Runtime.recent_attentions(assigns.view.attentions, assigns.now), else: []))

    ~H"""
    <section id="build-queue-panel" class="bo-surface" style="gap: 0.6rem" aria-label={Copy.text(:title)} data-queue-state={@state}>
      <header>
        <h2 style="margin: 0; font-size: 1.1rem">{Copy.text(:title)}</h2>
        <p :if={not inactive?(@state)} style={muted() <> "; margin-top: 0.25rem"}>{Copy.text(:intro)}</p>
      </header>
      <p :if={@state != :running} style={flat()} role="status">{Copy.text(@state)}</p>
      <%= if @view && not inactive?(@state) do %>
        <p :for={{name, source} <- Enum.sort(@view.model.sources)} style={muted()} data-queue-source={name} data-freshness={source.freshness}>
          <strong>{Copy.source_name(name)}</strong> · {Copy.text(:observed)}: {Copy.timestamp(source.observed_at)} ·
          {Copy.text(:age)}: {Copy.age(source.age_ms)} · {Copy.text(:freshness)}: {Copy.label(source.freshness)}
          <span :if={source.reasons != []}> · {Copy.reason(source.reasons)}</span>
        </p>
        <.queue :for={queue <- @view.model.queues} queue={queue} dimmed={dimmed?(queue, @view.model.sources)} />
      <% end %>
      <section :if={not inactive?(@state)}>
      <h3 style={heading()}>{Copy.text(:attentions)}</h3>
      <p :if={@view && @view.model.status != :unknown && @attentions == []} style={muted()}>{Copy.text(:no_attentions)}</p>
      <p :if={Enum.any?(@attentions, &(not &1["needs_attention"]))} style={muted()}>{Copy.text(:resolved_notice)}</p>
      <ul :if={@attentions != []} style={flat()}>
        <li :for={alert <- @attentions} data-queue-attention={if(alert["needs_attention"], do: "open", else: "resolved")}>
          <strong :if={not alert["needs_attention"]}>{Copy.text(:resolved)} · </strong>
          {alert["message"]} · {Copy.text(:observed)}: {alert["timestamp"]}
        </li>
      </ul>
      </section>
    </section>
    """
  end

  # A queue that is switched off or unsupported has no sources or attentions to
  # report; showing their Unknown placeholders would read as a fault.
  defp inactive?(state), do: state in [:disabled, :unsupported_tracker]

  attr(:queue, :map, required: true)
  attr(:dimmed, :boolean, required: true)

  defp queue(assigns) do
    ~H"""
    <section data-queue-id={@queue.queue_id}>
      <h3 style={heading()}>{@queue.name} <span :if={@queue.held} class="badge">{Copy.text(:held_queue)}</span></h3>
      <p style={flat()} data-queue-progress={Copy.progress_state(@queue)}>{Copy.progress(@queue)}</p>
      <div style="overflow-x: auto" tabindex="0" role="region" aria-label="Build queue items">
        <table class="bo-catalog-table" style="min-width: 48rem">
          <thead><tr>
            <th :for={key <- [:position, :ticket, :state, :waiting_on, :rank, :attentions]} scope="col">{Copy.text(key)}</th>
          </tr></thead>
          <tbody>
            <tr :for={item <- @queue.items} data-queue-item={item.number} data-item-state={item.state}>
              <td>{item.position || Copy.text(:none)}</td>
              <td style="white-space: nowrap">#{item.number}</td>
              <td class={if(@dimmed, do: "muted")} style={if(@dimmed, do: "opacity: 0.6")} data-readiness-dimmed={@dimmed}>
                <span class="badge" style="white-space: nowrap">{Copy.label(if(@dimmed, do: :unknown, else: item.state))}</span>
                <span :if={Map.get(item, :reason)}>{Copy.reason(item.reason)}</span>
              </td>
              <td>
                <% waiting = Enum.reject(item.prerequisites, &(&1.verdict == :satisfied)) %>
                <span :if={waiting == []}>{Copy.text(:no_prerequisites)}</span>
                <p :for={edge <- waiting} style={flat()}>{Copy.prerequisite(edge)}</p>
              </td>
              <td>{Copy.rank(item)}</td>
              <td>{if(item.attention, do: Copy.reason(item.attention), else: Copy.text(:none))}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp dimmed?(%{kind: :build_order, root: root}, sources),
    do: not current?(sources["tracker_observation"]) or not current?(sources["build_order:#{root}"])

  defp dimmed?(_queue, sources), do: not current?(sources["tracker_observation"])
  defp current?(source), do: match?(%{freshness: :current}, source)

  @spec state(map() | nil) :: atom()
  def state(nil), do: :loading
  def state(%{model: %{status: status}}) when status != :running, do: status

  def state(%{model: model}) do
    sources = Map.values(model.sources)

    cond do
      model.queues == [] -> :empty
      Enum.any?(sources, &(&1.freshness == :stale)) -> :stale
      sources == [] or Enum.any?(sources, &(&1.freshness != :current)) -> :unknown
      true -> :running
    end
  end
end
