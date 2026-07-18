defmodule AiurWeb.OperatorControlCenter.BuildOrderBreakdown do
  @moduledoc """
  Plan phase and epic (lane) breakdowns plus a compact KPI strip for the
  selected Build Order.

  This is a pure projection of the already-validated view model the graph
  renders: it never fetches independently and never re-runs the graph
  projection. Point totals fold each member's single complexity value; members
  with missing, ambiguous, or duplicate metadata are surfaced in an explicit
  warning bucket and excluded from totals rather than guessed. Phase is a
  rollout hint (DEC-010) and never implies readiness or gating.
  """

  use Phoenix.Component

  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Group, Node}

  @ready_statuses [:ready]
  @degraded_statuses [:provider_stale, :provider_unavailable, :structurally_invalid]

  attr(:model, :any, required: true)

  @spec build_order_breakdown(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_breakdown(assigns) do
    projection = projection(assigns.model)

    assigns =
      assigns
      |> assign(:projection, projection)
      |> assign(:ready?, projection.status in @ready_statuses)
      |> assign(:degraded?, projection.status in @degraded_statuses)

    ~H"""
    <section class="bo-breakdown" aria-labelledby="bo-breakdown-title">
      <div class="bo-breakdown-head">
        <h3 id="bo-breakdown-title">Plan distribution</h3>
        <p class="bo-breakdown-note">Phase is a rollout hint, not a readiness gate.</p>
      </div>

      <div :if={@degraded?} class="bo-state-card" role={degraded_role(@projection.status)}>
        <h4>{degraded_title(@projection.status)}</h4>
        <p>{degraded_message(@projection.status)}</p>
      </div>

      <div :if={@ready?} class="bo-breakdown-body">
        <dl class="bo-kpis" aria-label="Plan summary">
          <div class="bo-kpi"><dt>Members</dt><dd class="num">{@projection.kpis.members}</dd></div>
          <div class="bo-kpi"><dt>Complexity points</dt><dd class="num">{@projection.kpis.points}</dd></div>
          <div class="bo-kpi"><dt>Ready at start</dt><dd class="num">{@projection.kpis.ready_at_start}</dd></div>
          <div class="bo-kpi"><dt>Longest chain</dt><dd class="num">{@projection.kpis.longest_chain}</dd></div>
        </dl>

        <div class="bo-breakdown-tables">
          <.breakdown_table
            id="bo-phase-breakdown"
            dimension="Phase"
            caption="Members and complexity points per plan phase, a rollout hint that does not gate readiness."
            rows={@projection.phases}
          />
          <.breakdown_table
            id="bo-epic-breakdown"
            dimension="Epic"
            caption="Members and complexity points per epic lane."
            rows={@projection.epics}
          />
        </div>

        <div :if={@projection.warnings != []} class="bo-breakdown-warnings" role="status">
          <h4>Excluded from point totals</h4>
          <ul>
            <li :for={warning <- @projection.warnings}>
              <span class="mono">{member_label(warning)}</span> — {warning.reason}
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:dimension, :string, required: true)
  attr(:caption, :string, required: true)
  attr(:rows, :list, required: true)

  defp breakdown_table(assigns) do
    ~H"""
    <table id={@id} class="bo-breakdown-table">
      <caption class="sr-only">{@caption}</caption>
      <thead>
        <tr>
          <th scope="col">{@dimension}</th>
          <th scope="col" class="num">Tickets</th>
          <th scope="col" class="num">Points</th>
          <th scope="col"><span class="sr-only">Point share</span></th>
          <th scope="col">Members</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows} data-breakdown-key={to_string(row.key)}>
          <th scope="row">{row.label}</th>
          <td class="num">{row.count}</td>
          <td class="num">{points_display(row.points)}</td>
          <td>
            <span class="bo-bar" aria-hidden="true"><i style={"width:#{bar_percent(row.weight)}%"}></i></span>
          </td>
          <td class="bo-breakdown-members">{members_text(row.members)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Builds the pure breakdown projection from the view model: KPI facts, per-phase
  and per-epic rows, and the warning bucket of members excluded from point
  totals.
  """
  @spec projection(term()) :: map()
  def projection(%BuildOrderViewModel{} = model) do
    nodes_by_key = Map.new(model.nodes, &{&1.key, &1})
    phases = rows(model.phase_groups, nodes_by_key)
    epics = rows(model.lane_groups, nodes_by_key)

    %{
      status: model.status,
      kpis: kpis(model),
      phases: phases,
      epics: epics,
      warnings: warnings(model.nodes)
    }
  end

  def projection(_model), do: %{status: :provider_unavailable, kpis: empty_kpis(), phases: [], epics: [], warnings: []}

  defp kpis(model) do
    %{
      members: Map.get(model.summary, :members, 0),
      points: Enum.sum(Enum.map(model.nodes, &member_points/1)),
      ready_at_start: Map.get(model.summary, :ready_at_start, 0),
      longest_chain: Map.get(model.summary, :longest_chain, 0)
    }
  end

  defp empty_kpis, do: %{members: 0, points: 0, ready_at_start: 0, longest_chain: 0}

  defp rows(groups, nodes_by_key) do
    rows =
      Enum.map(groups, fn %Group{} = group ->
        members = Enum.map(group.node_keys, &Map.get(nodes_by_key, &1))
        points = members |> Enum.reject(&is_nil/1) |> Enum.map(&member_points/1) |> Enum.sum()

        %{
          key: group.key,
          label: group.label,
          count: group.count,
          points: points,
          members: members |> Enum.reject(&is_nil/1) |> Enum.map(&member_label/1)
        }
      end)

    max_points = rows |> Enum.map(& &1.points) |> max_points()
    Enum.map(rows, &Map.put(&1, :weight, weight(&1.points, max_points)))
  end

  defp max_points([]), do: 0
  defp max_points(points), do: Enum.max(points)

  defp weight(_points, 0), do: 0.0
  defp weight(points, max_points), do: points / max_points

  defp warnings(nodes) do
    nodes
    |> Enum.filter(&excluded?/1)
    |> Enum.map(fn %Node{} = node -> %{card: node.card, reason: exclusion_reason(node)} end)
  end

  defp member_points(%Node{plan: %{complexity: complexity}} = node) do
    if excluded?(node), do: 0, else: complexity
  end

  defp excluded?(%Node{plan: %{complexity: complexity}} = node),
    do: not is_integer(complexity) or duplicate?(node)

  defp duplicate?(%Node{diagnostics: diagnostics}),
    do: Enum.any?(diagnostics, &(&1.code == :duplicate_identity))

  defp exclusion_reason(%Node{plan: %{complexity: complexity}} = node) do
    cond do
      duplicate?(node) and not is_integer(complexity) -> "duplicate identity and unusable complexity"
      duplicate?(node) -> "duplicate identity"
      true -> "missing or invalid complexity"
    end
  end

  defp member_label(%{card: card}), do: member_label(card)
  defp member_label(%{identifier: "Unknown ticket"}), do: "Unknown ticket"
  defp member_label(%{identifier: identifier}) when is_binary(identifier), do: "#" <> identifier
  defp member_label(_card), do: "Unknown ticket"

  defp members_text([]), do: "—"
  defp members_text(members), do: Enum.join(members, ", ")

  defp points_display(0), do: "—"
  defp points_display(points), do: Integer.to_string(points)

  defp bar_percent(weight) when is_number(weight), do: weight |> Kernel.*(100) |> round()
  defp bar_percent(_weight), do: 0

  defp degraded_role(:structurally_invalid), do: "alert"
  defp degraded_role(_status), do: "status"

  defp degraded_title(:provider_stale), do: "Plan distribution is stale"
  defp degraded_title(:provider_unavailable), do: "Plan distribution unavailable"
  defp degraded_title(:structurally_invalid), do: "Plan distribution is structurally invalid"

  defp degraded_message(:provider_stale),
    do: "Showing no breakdown while the planning graph is a stale last-known-good snapshot."

  defp degraded_message(:provider_unavailable),
    do: "The planning graph is unavailable, so the plan breakdown cannot be computed."

  defp degraded_message(:structurally_invalid),
    do: "The planning graph is structurally invalid, so the plan breakdown cannot be computed."
end
