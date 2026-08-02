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
  alias AiurWeb.OperatorControlCenter.BuildOrderEpicIcon

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
    <section class="bo-breakdown" aria-label="Plan breakdown">
      <div :if={@degraded?} class="bo-state-card" role={degraded_role(@projection.status)}>
        <h4>{degraded_title(@projection.status)}</h4>
        <p>{degraded_message(@projection.status)}</p>
      </div>

      <div :if={@ready?} class="bo-breakdown-tables">
        <.breakdown_list dimension="Waves" rows={@projection.phases} />
        <.breakdown_list dimension="Epics" rows={@projection.epics} icons />
      </div>
      <p :if={@ready? and @projection.discovered_total > 0} class="bo-breakdown-drift">
        {@projection.baseline_total} baseline members; {@projection.discovered_total} added after start.
      </p>
    </section>
    """
  end

  attr(:dimension, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:icons, :boolean, default: false)

  defp breakdown_list(assigns) do
    ~H"""
    <section class="bo-breakdown-list" aria-label={"Members and complexity points per #{@dimension}"}>
      <h4 class="bo-breakdown-list-title">{@dimension}</h4>
      <article
        :for={row <- @rows}
        class="bo-breakdown-row"
        data-breakdown-key={to_string(row.key)}
      >
        <div class="bo-breakdown-row-top">
          <BuildOrderEpicIcon.build_order_epic_icon
            :if={@icons}
            lane={to_string(row.key)}
            class="bo-breakdown-row-ic"
            colored
          />
          <span class="bo-breakdown-row-name">{row.label}</span>
          <span class="bo-breakdown-row-stat"><span class="bo-breakdown-row-stat-label">tickets</span> <span class="num">{row.count}</span></span>
          <span class="bo-breakdown-row-stat"><span class="bo-breakdown-row-stat-label">points</span> <span class="num">{points_display(row.points)}</span></span>
        </div>
        <p :if={row.members != []} class="bo-breakdown-row-members">{members_text(row.members)}</p>
        <span class="bo-breakdown-row-bar" aria-hidden="true"><i style={"width:#{bar_percent(row.weight)}%"}></i></span>
      </article>
    </section>
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
    {baseline_total, discovered_total} = provenance_totals(model.nodes)

    %{
      status: model.status,
      kpis: kpis(model),
      phases: phases,
      epics: epics,
      baseline_total: baseline_total,
      discovered_total: discovered_total,
      warnings: warnings(model.nodes)
    }
  end

  def projection(_model),
    do: %{status: :provider_unavailable, kpis: empty_kpis(), phases: [], epics: [], baseline_total: 0, discovered_total: 0, warnings: []}

  defp kpis(model) do
    %{
      members: Map.get(model.summary, :members, 0),
      points: Enum.sum(Enum.map(model.nodes, &member_points/1)),
      ready_at_start: Map.get(model.summary, :ready_at_start, 0),
      longest_chain: Map.get(model.summary, :longest_chain, 0)
    }
  end

  defp empty_kpis, do: %{members: 0, points: 0, ready_at_start: 0, longest_chain: 0}

  defp provenance_totals(nodes) do
    Enum.reduce(nodes, {0, 0}, fn node, {baseline_total, discovered_total} ->
      if discovered?(node), do: {baseline_total, discovered_total + 1}, else: {baseline_total + 1, discovered_total}
    end)
  end

  defp discovered?(%Node{plan: %{provenance: :discovered}}), do: true
  defp discovered?(_node), do: false

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
