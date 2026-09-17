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

  Each wave and epic row also carries completion on the same basis as the
  graph above it (`BuildOrderGridModel.member_completion/1` folded with
  `BuildOrderGridModel.aggregate/1`): accepted lifecycle completion first, then
  a fresh or last-known worker reading at face value, and otherwise unresolved.
  Unresolved members reduce the row's coverage (`:partial`) instead of counting
  as 0%, and the row's `last_known` marker says how many members are carried by
  retained readings and how old the oldest is, so retained work is neither
  erased into 0% nor mistaken for current. The row renders through
  `ProgressRenderer`, the same boundary every other completion surface uses.
  """

  use Phoenix.Component

  alias Aiur.BuildOrder.AdHocSource.Snapshot, as: AdHocSnapshot
  alias Aiur.BuildOrder.{Bounded, Metadata, ProgressRenderer}
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Group, Node}
  alias AiurWeb.OperatorControlCenter.{BuildOrderEpicIcon, BuildOrderGridModel}

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
    <section class="bo-breakdown" aria-label="Waves and Epics">
      <div :if={@degraded?} class="bo-state-card" role={degraded_role(@projection.status)}>
        <h4>{degraded_title(@projection.status)}</h4>
        <p>{degraded_message(@projection.status)}</p>
      </div>

      <div :if={@ready?} class="bo-breakdown-tables">
        <.breakdown_list dimension="Waves" rows={@projection.phases} />
        <.breakdown_list dimension="Epics" rows={@projection.epics} icons />
      </div>
    </section>
    """
  end

  attr(:dimension, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:icons, :boolean, default: false)

  defp breakdown_list(assigns) do
    ~H"""
    <section
      class="bo-breakdown-list"
      aria-label={"Ticket progress, members, and complexity points per #{@dimension}"}
    >
      <h4 class="bo-breakdown-list-title">{@dimension}</h4>
      <article
        :for={%{progress_view: view} = row <- @rows}
        class="bo-breakdown-row"
        data-breakdown-key={to_string(row.key)}
        data-breakdown-progress={view.percent}
        data-breakdown-resolution={view.state}
        data-breakdown-last-known={to_string(row.last_known.count)}
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
          <span class="bo-breakdown-row-stat" data-progress-state={view.state} data-progress-freshness={view.freshness} title={view.title} aria-label={view.aria_label}>
            <span class="bo-breakdown-row-stat-label">done</span> <span class="num">{progress_display(row, view)}</span>
          </span>
          <span :if={view.note} class="bo-breakdown-row-stat bo-breakdown-row-last-known" title={view.title}>
            <span class="bo-breakdown-row-stat-label">last known</span> <span class="num">{row.last_known.count}</span> <span class="bo-breakdown-row-age">{view.note}</span>
          </span>
        </div>
        <p :if={row.members != []} class="bo-breakdown-row-members">{members_text(row.members)}</p>
        <span class="bo-breakdown-row-bar" aria-hidden="true"><i style={"width:#{view.percent || 0}%"}></i></span>
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
        members = group.node_keys |> Enum.map(&Map.get(nodes_by_key, &1)) |> Enum.reject(&is_nil/1)

        completion = group_completion(members)

        %{
          key: group.key,
          label: group.label,
          count: group.count,
          points: members |> Enum.map(&member_points/1) |> Enum.sum(),
          completion: completion,
          progress_view: ProgressRenderer.html(completion),
          progress: Map.get(completion, :progress),
          last_known: %{count: Map.get(completion, :stale_count, 0), observed_at: Map.get(completion, :stale_observed_at)},
          members: Enum.map(members, &member_label/1)
        }
      end)

    max_points = rows |> Enum.map(& &1.points) |> max_points()
    Enum.map(rows, &Map.put(&1, :weight, weight(&1.points, max_points)))
  end

  # Completion for one row is the same complexity-weighted aggregate the graph
  # uses, over the same per-member basis, so the lower breakdown and the top
  # bars cannot disagree: a member with no usable reading reduces coverage
  # (`:partial`) instead of being counted as 0%, and a retained reading keeps
  # its percent tagged as last known.
  defp group_completion(members) do
    members
    |> Enum.map(&%{completion: BuildOrderGridModel.member_completion(&1), complexity: member_weight(&1)})
    |> BuildOrderGridModel.aggregate()
  end

  defp member_weight(node) do
    case member_points(node) do
      points when is_integer(points) and points > 0 -> points
      _points -> nil
    end
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

  defp progress_display(%{count: 0}, _view), do: "—"
  defp progress_display(_row, %{label: label}), do: label

  defp degraded_role(:structurally_invalid), do: "alert"
  defp degraded_role(_status), do: "status"

  defp degraded_title(:provider_stale), do: "Plan distribution unavailable"
  defp degraded_title(:provider_unavailable), do: "Plan distribution unavailable"
  defp degraded_title(:structurally_invalid), do: "Plan distribution is unreadable"

  defp degraded_message(:provider_stale),
    do: "The plan is unavailable, so the breakdown cannot be worked out."

  defp degraded_message(:provider_unavailable),
    do: "The plan is unavailable, so the breakdown cannot be worked out."

  defp degraded_message(:structurally_invalid),
    do: "The plan is unreadable, so the breakdown cannot be worked out."
end
