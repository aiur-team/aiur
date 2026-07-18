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

  alias Aiur.BuildOrder.AdHocSource.Snapshot, as: AdHocSnapshot
  alias Aiur.BuildOrder.{Bounded, Metadata}
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Group, Node}

  @ready_statuses [:ready]
  @degraded_statuses [:provider_stale, :provider_unavailable, :structurally_invalid]

  attr(:model, :any, required: true)
  attr(:adhoc, :any, default: nil)

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

      <.adhoc_section :if={not is_nil(@adhoc)} adhoc={@adhoc} />
    </section>
    """
  end

  attr(:adhoc, :any, required: true)

  defp adhoc_section(assigns) do
    ~H"""
    <section class="bo-adhoc" aria-labelledby="bo-adhoc-title">
      <div class="bo-breakdown-head">
        <h3 id="bo-adhoc-title">Ad Hoc epic</h3>
        <p class="bo-breakdown-note">
          Tickets created or promoted during the run. Tracked separately — excluded from the
          core member, point, critical-path, and ETA totals above.
        </p>
      </div>

      <div :if={@adhoc.status in [:stale, :unavailable]} class="bo-state-card" role="status">
        <h4>{adhoc_state_title(@adhoc.status)}</h4>
        <p>{adhoc_state_message(@adhoc.status)}</p>
      </div>

      <div :if={@adhoc.status == :available} class="bo-adhoc-body">
        <p class="bo-adhoc-total">
          <span class="num">{@adhoc.total}</span> ad hoc {ticket_word(@adhoc.total)}
        </p>

        <div :if={@adhoc.total == 0} class="bo-state-card" role="status">
          <h4>No ad hoc tickets yet</h4>
          <p>No issues carry the <span class="mono">build-lane:adhoc</span> label in this run.</p>
        </div>

        <table :if={@adhoc.total > 0} id="bo-adhoc-breakdown" class="bo-breakdown-table bo-adhoc-table">
          <caption class="sr-only">
            Ad Hoc tickets grouped by the phase they were picked up in; tickets never picked up
            appear as TBD / not picked. Live state comes from Aiur and completion from GitHub.
          </caption>
          <thead>
            <tr>
              <th scope="col">Pickup phase</th>
              <th scope="col">Ticket</th>
              <th scope="col">State</th>
              <th scope="col" class="num">Progress</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @adhoc.rows}
              data-adhoc-ticket={row.identifier}
              data-adhoc-phase={phase_key(row)}
            >
              <td>{phase_label(row)}</td>
              <th scope="row" class="bo-adhoc-ticket">
                <a :if={row.href} href={row.href}>{ticket_label(row)}</a>
                <span :if={is_nil(row.href)}>{ticket_label(row)}</span>
              </th>
              <td>
                <span class={"bo-adhoc-state bo-adhoc-state-#{adhoc_state_class(row)}"}>
                  {adhoc_state_text(row)}
                </span>
              </td>
              <td class="num">{progress_display(row.progress)}</td>
            </tr>
          </tbody>
        </table>
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

  @doc """
  Builds the derived Ad Hoc epic overlay: the `build-lane:adhoc` snapshot joined
  with live execution/activity for progress and live-agent state.

  This is a runtime overlay — its rows never fold into the core member, point,
  critical-path, or ETA totals. Pickup phase is the frozen `phase:N` label read
  live off each issue; members without a phase label render as TBD / not picked.
  Completed and duplicate tickets remain visible; lifecycle is GitHub open/closed
  and never inferred from free-form status text.
  """
  @spec adhoc_projection(term(), term(), term()) :: map()
  def adhoc_projection(%AdHocSnapshot{} = snapshot, execution, activity) do
    running = running_identity_set(execution)
    progress = progress_by_identity(activity)

    rows =
      snapshot.members
      |> Enum.map(&adhoc_row(&1, running, progress))
      |> Enum.sort_by(&adhoc_row_sort_key/1)

    %{status: snapshot.status, total: length(rows), rows: rows}
  end

  def adhoc_projection(_snapshot, _execution, _activity),
    do: %{status: :unavailable, total: 0, rows: []}

  defp adhoc_row(member, running, progress) do
    meta = Metadata.parse(member.labels)
    key = identity_key(member.identity)

    %{
      identifier: member.identifier,
      title: member.title,
      href: adhoc_href(member.url),
      lifecycle: member.lifecycle,
      phase: meta.phase,
      complexity: meta.complexity,
      running?: not is_nil(key) and MapSet.member?(running, key),
      progress: key && Map.get(progress, key)
    }
  end

  defp adhoc_row_sort_key(%{phase: phase, identifier: identifier}) do
    case phase do
      phase when is_integer(phase) -> {0, phase, adhoc_id_sort(identifier)}
      _unphased -> {1, 0, adhoc_id_sort(identifier)}
    end
  end

  defp adhoc_id_sort(identifier) do
    case Integer.parse(to_string(identifier)) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  @spec running_identity_set(term()) :: MapSet.t()
  defp running_identity_set(%{running: running}) when is_list(running) do
    running
    |> Enum.map(&identity_key(Map.get(&1, :tracker_identity)))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp running_identity_set(_execution), do: MapSet.new()

  defp progress_by_identity(%{entries: entries}) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      with key when not is_nil(key) <- identity_key(Map.get(entry, :identity)),
           %{status: :known, percent: percent} when percent in 0..100 <- Map.get(entry, :progress) do
        Map.put(acc, key, percent)
      else
        _other -> acc
      end
    end)
  end

  defp progress_by_identity(_activity), do: %{}

  defp identity_key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)
  defp identity_key(_identity), do: nil

  defp adhoc_href(url) do
    case Bounded.github_url(url) do
      {:ok, safe} -> safe
      :error -> nil
    end
  end

  defp phase_key(%{phase: phase}) when is_integer(phase), do: Integer.to_string(phase)
  defp phase_key(_row), do: "tbd"

  defp phase_label(%{phase: phase}) when is_integer(phase), do: "Phase #{phase}"
  defp phase_label(_row), do: "TBD / not picked"

  defp ticket_label(%{identifier: identifier, title: title}) when is_binary(title) and title != "",
    do: "#" <> to_string(identifier) <> " — " <> title

  defp ticket_label(%{identifier: identifier}), do: "#" <> to_string(identifier)

  defp ticket_word(1), do: "ticket"
  defp ticket_word(_count), do: "tickets"

  defp adhoc_state_text(%{running?: true}), do: "Live agent"
  defp adhoc_state_text(%{lifecycle: :closed}), do: "Closed"
  defp adhoc_state_text(_row), do: "Open"

  defp adhoc_state_class(%{running?: true}), do: "live"
  defp adhoc_state_class(%{lifecycle: :closed}), do: "done"
  defp adhoc_state_class(_row), do: "open"

  defp progress_display(percent) when is_integer(percent) and percent in 0..100,
    do: Integer.to_string(percent) <> "%"

  defp progress_display(_percent), do: "—"

  defp adhoc_state_title(:stale), do: "Ad Hoc overlay is stale"
  defp adhoc_state_title(:unavailable), do: "Ad Hoc overlay unavailable"

  defp adhoc_state_message(:stale),
    do: "Showing the last-known-good ad hoc overlay while the live source is stale."

  defp adhoc_state_message(:unavailable),
    do: "The ad hoc overlay source is unavailable, so ad hoc tickets cannot be listed."

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
