defmodule AiurWeb.OperatorControlCenter.DecisionInbox do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.{DecisionCard, DecisionPath}

  @filter_specs [
    {:open, "Open"},
    {:blocking, "Blocking"},
    {:resolved, "Resolved"},
    {:all, "All"}
  ]

  attr(:decisions, :list, required: true)
  attr(:selected_decision, :map, default: nil)
  attr(:selected_decision_id, :string, default: nil)
  attr(:filter, :atom, default: :all)
  attr(:now, :any, required: true)
  attr(:history, :list, default: [])
  attr(:action_states, :map, default: %{})
  attr(:writable, :boolean, required: true)
  attr(:provider_health, :any, default: :ok)
  attr(:retained_counts, :map, required: true)
  attr(:page, :map, default: %{})
  attr(:query, :map, default: %{})

  @spec decision_inbox(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_inbox(assigns) do
    decisions = visible_decisions(assigns.decisions, assigns.selected_decision, assigns.selected_decision_id, assigns.filter)

    assigns =
      assigns
      |> assign(:visible_decisions, decisions)
      |> assign(:counts, filter_counts(assigns.retained_counts, assigns.page, assigns.filter))
      |> assign(:filter_specs, @filter_specs)
      |> assign(:search, Map.get(assigns.query, :search, ""))
      |> assign(:page_health, get_in(assigns.page, [:health, :status]))
      |> assign(:pagination, Map.get(assigns.page, :pagination, %{}))
      |> assign(:next_path, next_path(assigns.page, assigns.query, assigns.filter))

    ~H"""
    <section class="section-card decision-inbox" aria-labelledby="decision-inbox-title">
      <h2 id="decision-inbox-title" class="sr-only">Commands inbox</h2>

      <div class="filter-row" aria-label="Command filters">
        <.filter_button
          :for={{filter, label} <- @filter_specs}
          filter={Atom.to_string(filter)}
          label={label}
          count={Map.fetch!(@counts, filter)}
          active={@filter == filter}
          blocking={filter == :blocking}
        />
      </div>

      <form :if={@filter == :all} class="command-search" role="search" phx-submit="search-commands">
        <label for="command-search">Search retained Commands</label>
        <div class="command-search-controls">
          <input
            id="command-search"
            name="search"
            value={@search}
            maxlength="200"
            placeholder="Command ID or ticket ID"
            autocomplete="off"
          />
          <button type="submit" class="btn secondary">Search</button>
          <.link :if={@search != ""} patch={DecisionPath.inbox(:all)} class="btn ghost">Clear</.link>
        </div>
      </form>

      <div class="decision-list">
        <div :if={@provider_health != :ok or @page_health == :unavailable} class="empty-state">
          Command projection is currently unavailable. Unit state remains live.
        </div>
        <div :if={@page_health == :partial} class="empty-state compact" role="status">
          Retained Commands are partial; showing the last validated audit prefix.
        </div>
        <div :if={@provider_health == :ok and @page_health != :unavailable and @visible_decisions == []} class="empty-state">
          No Commands match this filter.
        </div>
        <DecisionCard.decision_card
          :for={decision <- @visible_decisions}
          decision={decision}
          selected={decision.decision_id == @selected_decision_id}
          now={@now}
          history={@history}
          action_state={Map.get(@action_states, decision.decision_id, %{})}
          writable={@writable}
          filter={@filter}
          query={@query}
        />
      </div>

      <nav :if={map_size(@pagination) > 0} class="command-pagination" aria-label="Retained Command pages">
        <span class="muted">{pagination_label(@pagination)}</span>
        <.link :if={@next_path} patch={@next_path} class="btn ghost">Next page</.link>
      </nav>
    </section>
    """
  end

  attr(:filter, :string, required: true)
  attr(:label, :string, required: true)
  attr(:count, :any, required: true)
  attr(:active, :boolean, required: true)
  attr(:blocking, :boolean, default: false)

  defp filter_button(assigns) do
    ~H"""
    <button
      type="button"
      class={["filter-chip", @active && "is-active", @blocking && "blocking"]}
      phx-click="filter-decisions"
      phx-value-filter={@filter}
      aria-pressed={to_string(@active)}
    >
      {@label} <span class="count num">{count_label(@count)}</span>
    </button>
    """
  end

  defp filter_counts(retained_counts, page, filter) do
    resolved = if filter == :resolved, do: get_in(page, [:pagination, :total])

    %{
      all: Map.get(retained_counts, :total),
      open: Map.get(retained_counts, :open),
      blocking: Map.get(retained_counts, :blocking),
      resolved: resolved
    }
  end

  defp count_label(count) when is_integer(count), do: count
  defp count_label(_count), do: "—"

  defp filtered(decisions, :open), do: Enum.filter(decisions, &open?/1)
  defp filtered(decisions, :blocking), do: Enum.filter(decisions, &blocking?/1)
  defp filtered(decisions, :undelivered), do: Enum.filter(decisions, &undelivered?/1)
  defp filtered(decisions, :supervisor), do: Enum.filter(decisions, &supervisor_decision?/1)
  defp filtered(decisions, :resolved), do: Enum.filter(decisions, &(&1.decision_status == :resolved))
  defp filtered(decisions, :superseded), do: Enum.filter(decisions, &Map.get(&1, :superseded?, false))
  defp filtered(decisions, _filter), do: decisions

  defp visible_decisions(decisions, selected, selected_id, filter) do
    filtered =
      decisions
      |> Enum.reject(&(&1.decision_id == selected_id))
      |> filtered(filter)

    if is_nil(selected), do: filtered, else: [selected | filtered]
  end

  defp open?(decision), do: decision.decision_status == :open
  defp blocking?(decision), do: decision.blocking and open?(decision)

  defp undelivered?(decision) do
    not is_nil(decision.answer) and decision.delivery_status not in [:delivered, :consumed]
  end

  defp supervisor_decision?(decision) do
    get_in(decision, [:answer, :actor, :kind]) == :supervisor
  end

  defp next_path(page, query, filter) do
    case get_in(page, [:pagination, :next_cursor]) do
      cursor when is_binary(cursor) ->
        query = query |> Map.take([:search]) |> Map.put(:cursor, cursor)
        DecisionPath.inbox(filter, query)

      _cursor ->
        nil
    end
  end

  defp pagination_label(%{label: label}) when is_binary(label), do: command_vocabulary(label)
  defp pagination_label(_pagination), do: "Retained Command page"

  defp command_vocabulary(label) do
    label
    |> String.replace("Decisions", "Commands")
    |> String.replace("Decision", "Command")
  end
end
