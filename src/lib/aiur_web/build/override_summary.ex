defmodule AiurWeb.Build.OverrideSummary do
  @moduledoc "Pending Command overrides on the current fleet overview."
  use Phoenix.Component
  alias Aiur.Commands
  alias AiurWeb.EndpointConfig

  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket), do: assign(socket, :fleet_overrides, load())

  @spec load(keyword()) :: {:ok, [map()]} | :unavailable
  def load(opts \\ []) do
    store = Keyword.get(opts, :store, EndpointConfig.get(:decision_store) || Commands.default_store())

    case Commands.query_counts(store: store) do
      {:ok, %{health: %{status: :available}}} -> {:ok, store |> Commands.list_decisions(1_000) |> rows()}
      _unknown -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  @spec rows([map()]) :: [map()]
  def rows(decisions) do
    decisions
    |> Enum.flat_map(fn decision ->
      case Commands.pending_override_status(decision) do
        nil -> []
        override -> [%{decision_id: decision.decision_id, ticket: Commands.override_target_ticket(decision).identifier, label: override.label}]
      end
    end)
    |> Enum.sort_by(&{&1.ticket, &1.decision_id})
  end

  attr(:state, :any, required: true)

  @spec summary(map()) :: Phoenix.LiveView.Rendered.t()
  def summary(assigns) do
    ~H"""
    <section :if={@state != {:ok, []}} id="fleet-overrides" class="detail-block" aria-label="Fleet overrides">
      <h2>Pending overrides</h2>
      <p :if={@state == :unavailable}>Override status unavailable</p>
      <ul :if={is_tuple(@state)} class="decision-timeline">
        <li :for={row <- elem(@state, 1)}>
          <.link navigate={AiurWeb.OperatorControlCenter.DecisionPath.detail(row.decision_id, :all)} class="chip attention fleet-override-badge">
            Ticket #{row.ticket} · {row.label}
          </.link>
        </li>
      </ul>
    </section>
    """
  end
end
