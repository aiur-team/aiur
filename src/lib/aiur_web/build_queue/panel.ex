defmodule AiurWeb.BuildQueue.Panel do
  @moduledoc "Read-only build queue panel for the Build Order catalog."
  use Phoenix.Component
  alias AiurWeb.BuildQueue.{Copy, Runtime}

  attr(:view, :map, default: nil)
  attr(:now, :any, required: true)

  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    assigns = assigns |> assign(:state, state(assigns.view)) |> assign(:attentions, if(assigns.view, do: Runtime.recent_attentions(assigns.view.attentions, assigns.now), else: []))

    ~H"""
    <section id="build-queue-panel" class="bo-surface" aria-label={Copy.text(:title)} data-queue-state={@state}>
      <h2>{Copy.text(:title)}</h2>
      <p>{Copy.text(:intro)}</p>
      <p :if={@state != :running} role="status">{Copy.text(@state)}</p>
      <%= if @view do %>
        <p :for={{name, source} <- Enum.sort(@view.model.sources)} data-queue-source={name} data-freshness={source.freshness}>
          <strong>{name}</strong> · {Copy.text(:observed)}: {Copy.timestamp(source.observed_at)} ·
          {Copy.text(:age)}: {Copy.age(source.age_ms)} · {Copy.text(:freshness)}: {Copy.label(source.freshness)}
          <span :if={source.reasons != []}> · {Copy.reason(source.reasons)}</span>
        </p>
        <.queue :for={queue <- @view.model.queues} queue={queue} dimmed={dimmed?(queue, @view.model.sources)} />
      <% end %>
      <h3>{Copy.text(:attentions)}</h3>
      <p :if={@view && @view.model.status != :unknown && @attentions == []}>{Copy.text(:no_attentions)}</p>
      <p :if={Enum.any?(@attentions, &(not &1["needs_attention"]))}>{Copy.text(:resolved_notice)}</p>
      <ul :if={@attentions != []}>
        <li :for={alert <- @attentions} data-queue-attention={if(alert["needs_attention"], do: "open", else: "resolved")}>
          <strong :if={not alert["needs_attention"]}>{Copy.text(:resolved)} · </strong>
          {alert["message"]} · {Copy.text(:observed)}: {alert["timestamp"]}
        </li>
      </ul>
    </section>
    """
  end

  attr(:queue, :map, required: true)
  attr(:dimmed, :boolean, required: true)

  defp queue(assigns) do
    ~H"""
    <section data-queue-id={@queue.queue_id}>
      <h3>{@queue.name} <span :if={@queue.held} class="badge">{Copy.text(:held_queue)}</span></h3>
      <p data-queue-progress={Copy.progress_state(@queue)}>{Copy.progress(@queue)}</p>
      <div style="overflow-x: auto">
        <table class="bo-catalog-table">
          <thead><tr>
            <th :for={key <- [:position, :ticket, :state, :waiting_on, :rank, :attentions]} scope="col">{Copy.text(key)}</th>
          </tr></thead>
          <tbody>
            <tr :for={item <- @queue.items} data-queue-item={item.number} data-item-state={item.state}>
              <td>{item.position || Copy.text(:none)}</td>
              <td>#{item.number}</td>
              <td class={if(@dimmed, do: "muted")} style={if(@dimmed, do: "opacity: 0.6")} data-readiness-dimmed={@dimmed}>
                <span class="badge">{Copy.label(if(@dimmed, do: :unknown, else: item.state))}</span>
                <span :if={Map.get(item, :reason)}>{Copy.reason(item.reason)}</span>
              </td>
              <td>
                <% waiting = Enum.reject(item.prerequisites, &(&1.verdict == :satisfied)) %>
                <span :if={waiting == []}>{Copy.text(:no_prerequisites)}</span>
                <p :for={edge <- waiting}>{Copy.prerequisite(edge)}</p>
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
