defmodule AiurWeb.OperatorControlCenter.BuildOrderSelected do
  @moduledoc "Selected-root state and graph surface for Build Order routes."

  use Phoenix.Component

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.SelectedRoot
  alias AiurWeb.BuildOrder.RouteState
  alias AiurWeb.OperatorControlCenter.{BuildOrderAnalytics, BuildOrderBreakdown, BuildOrderGraph, BuildOrderUsage}

  attr(:route_state, :any, required: true)
  attr(:model, :any, default: nil)
  attr(:adhoc, :any, default: nil)
  attr(:now, :any, required: true)
  attr(:analytics_scope, :map, required: true)
  attr(:analytics_model, :any, default: nil)
  attr(:analytics_unavailable, :any, default: nil)
  attr(:analytics_loading, :boolean, default: false)
  attr(:time_domain, :any, default: nil)
  attr(:usage_scope, :map, required: true)
  attr(:usage_view, :map, default: nil)
  attr(:usage_announcement, :string, default: nil)
  attr(:usage_drill_down, :map, default: nil)
  attr(:usage_drill_trigger, :string, default: nil)

  @spec build_order_selected(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_selected(assigns) do
    assigns =
      assigns
      |> assign(:status, RouteState.status(assigns.route_state))
      |> assign(:snapshot, RouteState.selected_snapshot(assigns.route_state))
      |> assign(:graph_failure, graph_failure(assigns.model, assigns.route_state))

    ~H"""
    <header class="bo-page-header">
      <.link patch="/build-orders" class="bo-back-link" aria-label="Back to all Build Orders">‹</.link>
      <h2 id="build-order-selected-title">{selected_title(@status, @snapshot, RouteState.root_identifier(@route_state))}</h2>
    </header>

    <section class="bo-surface" aria-labelledby="build-order-selected-title">
      <div :if={@graph_failure} class="bo-state-card bo-error-state" role={@graph_failure.role}>
        <h3>{@graph_failure.title}</h3>
        <p>{@graph_failure.message}</p>
        <p class="bo-error-fault">
          Reported fault: <code>{@graph_failure.code}</code>
        </p>

        <div id="build-order-debug-prompt-copy" class="bo-debug-prompt" phx-hook="CopyToClipboard">
          <label for="build-order-debug-prompt">Debug prompt</label>
          <textarea id="build-order-debug-prompt" rows="4" readonly data-copy-source>{@graph_failure.prompt}</textarea>
          <div class="bo-debug-prompt-actions">
            <button type="button" class="bo-debug-copy-button" data-copy-trigger>
              Copy debug prompt
            </button>
            <span id="build-order-debug-prompt-status" role="status" aria-live="polite" data-copy-status></span>
          </div>
        </div>
      </div>

      <div :if={is_nil(@graph_failure) and is_nil(@model)} class="bo-state-card" role={state_role(@status)}>
        <h3>{state_title(@status)}</h3>
        <p>{state_message(@status)}</p>
      </div>

      <div :if={is_nil(@graph_failure) and not is_nil(@model)} class="bo-selected-summary">
        <div :if={@model.status not in [:ready, :empty]} class="bo-state-card" role={model_state_role(@model)}>
          <h3>{model_state_title(@model)}</h3>
          <p>{model_summary(@model)}</p>
        </div>
        <dl class="bo-summary-grid" aria-label="Build Order graph summary">
          <div><dt>Members</dt><dd>{metric(@model.summary, @model.summary.members)}</dd></div>
          <div><dt>Dependencies</dt><dd>{metric(@model.summary, @model.summary.edges)}</dd></div>
          <div><dt>External</dt><dd>{metric(@model.summary, @model.summary.external_edges)}</dd></div>
          <div><dt>Lanes</dt><dd>{metric(@model.summary, map_size(@model.summary.lanes))}</dd></div>
          <div><dt>Waves</dt><dd>{metric(@model.summary, map_size(@model.summary.phases))}</dd></div>
        </dl>

        <div :if={@model.status == :empty} class="bo-state-card" role="status">
          <h3>Valid empty graph</h3>
          <p>This Build Order currently has no direct members.</p>
        </div>

        <BuildOrderGraph.build_order_graph
          :if={@model.nodes != []}
          id="selected-build-order-graph"
          root_id={RouteState.root_identifier(@route_state)}
          provider_generation={positive_generation(@snapshot)}
          dom_generation={max(RouteState.dom_generation(@route_state), 1)}
          model={@model}
          adhoc={@adhoc}
        />

        <BuildOrderBreakdown.build_order_breakdown :if={@model.status != :empty} model={@model} adhoc={@adhoc} />

        <BuildOrderAnalytics.build_order_analytics
          :if={@model.status != :empty}
          scope={@analytics_scope}
          model={@analytics_model}
          unavailable={@analytics_unavailable}
          loading={@analytics_loading}
          time_domain={@time_domain}
        />

        <BuildOrderUsage.build_order_usage
          :if={@model.status != :empty}
          scope={@usage_scope}
          view={@usage_view}
          announcement={@usage_announcement}
          drill_down={@usage_drill_down}
          drill_trigger={@usage_drill_trigger}
        />

        <ul :if={@model.diagnostics != []} class="bo-diagnostics" aria-label="Build Order diagnostics">
          <li :for={diagnostic <- @model.diagnostics}>{diagnostic.text}</li>
        </ul>
      </div>
    </section>
    """
  end

  # One upstream read fault degrades the whole page. State it once, name the
  # specific code the provider actually reported, and hand the operator a prompt
  # that already carries what an agent needs to start.
  defp graph_failure(model, route_state) do
    case failure_kind(model, RouteState.status(route_state)) do
      nil ->
        nil

      kind ->
        snapshot = RouteState.selected_snapshot(route_state)

        failure(kind, %{
          identifier: RouteState.root_identifier(route_state),
          code: failure_code(model, snapshot, kind),
          model: model,
          snapshot: snapshot
        })
    end
  end

  defp failure_kind(%{status: :provider_unavailable}, _route_status), do: :unfetched
  defp failure_kind(%{status: :structurally_invalid}, _route_status), do: :malformed
  defp failure_kind(nil, :selected_unavailable), do: :unfetched
  defp failure_kind(nil, :selected_invalid), do: :malformed
  defp failure_kind(_model, _route_status), do: nil

  # `failure_class/1` preserves the specific code (`rate_limited`, `permission`,
  # `schema`, …). Report that, never a laundered stand-in for every outage.
  defp failure_code(model, snapshot, kind) do
    Enum.find([health_failure(model), snapshot_failure(snapshot), default_code(kind)], &(is_atom(&1) and not is_nil(&1)))
  end

  defp health_failure(%{planning_health: %{failure: failure}}) when is_atom(failure), do: failure
  defp health_failure(_model), do: nil

  defp snapshot_failure(%Snapshot{health: %{failure: failure}}) when is_atom(failure), do: failure
  defp snapshot_failure(_snapshot), do: nil

  defp default_code(:unfetched), do: :provider_unavailable
  defp default_code(:malformed), do: :structurally_invalid

  defp failure(:unfetched, context) do
    %{
      role: "status",
      code: context.code,
      title: "Could not fetch planning graph",
      message: "The selected-root provider did not return a graph, so its counts and dependent views are unavailable.",
      prompt:
        "Investigate why #{root_label(context.identifier)}'s planning graph could not be fetched. " <>
          "The selected-root provider reports `#{context.code}`#{scope_suffix(context.snapshot)}; " <>
          "graph counts are unresolved#{diagnostic_suffix(context.model, context.code)}."
    }
  end

  defp failure(:malformed, context) do
    %{
      role: "alert",
      code: context.code,
      title: "Fetched planning graph is malformed",
      message: "The selected-root provider returned a graph that failed structural validation.",
      prompt:
        "Investigate why #{root_label(context.identifier)}'s fetched planning graph is malformed. " <>
          "The selected-root provider reports `#{context.code}`#{scope_suffix(context.snapshot)}" <>
          "#{member_observation(context.model)}#{diagnostic_suffix(context.model, context.code)}."
    }
  end

  defp scope_suffix(%Snapshot{repository: repository, generation: generation}) do
    [repository_clause(repository), generation_clause(generation)]
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ""
      clauses -> " (" <> Enum.join(clauses, ", ") <> ")"
    end
  end

  defp scope_suffix(_snapshot), do: ""

  defp repository_clause({owner, name}) when is_binary(owner) and is_binary(name),
    do: "reading the selected-root graph for #{owner}/#{name}"

  defp repository_clause(_repository), do: "reading the selected-root graph"

  defp generation_clause(generation) when is_integer(generation) and generation > 0, do: "provider generation #{generation}"
  defp generation_clause(_generation), do: ""

  defp root_label(identifier) when is_binary(identifier), do: "Build Order ##{identifier}"
  defp root_label(_identifier), do: "the selected Build Order"

  defp member_observation(%{summary: %{resolved?: true, members: members}}) when is_integer(members),
    do: " with `members: #{members}`"

  defp member_observation(_model), do: "; the fetched response failed structural validation"

  # Only genuinely distinct faults earn a mention. A diagnostic that restates the
  # reported fault is the same fact twice, which is the defect this state fixes.
  defp diagnostic_suffix(%{diagnostics: diagnostics}, code) when is_list(diagnostics) do
    codes =
      diagnostics
      |> Enum.map(&Map.get(&1, :code))
      |> Enum.filter(&is_atom/1)
      |> Enum.reject(&restates?(&1, code))
      |> Enum.uniq()
      |> Enum.sort()

    case codes do
      [] -> ""
      codes -> "; also reported: " <> Enum.map_join(codes, ", ", &"`#{&1}`")
    end
  end

  defp diagnostic_suffix(_model, _code), do: ""

  defp restates?(code, code), do: true
  defp restates?(:provider_unavailable, _code), do: true
  defp restates?(_diagnostic_code, _code), do: false

  # An unresolved graph has no counts to show. Rendering the zeros of an empty
  # model would state a number we never read — "Unresolved" is the honest cell.
  defp metric(%{resolved?: false}, _value), do: "Unresolved"
  defp metric(_summary, value), do: value

  defp selected_title(_status, %Snapshot{data: %SelectedRoot{root: root}}, _identifier), do: root.title
  defp selected_title(_status, _snapshot, identifier) when is_binary(identifier), do: "Build Order ##{identifier}"
  defp selected_title(_status, _snapshot, _identifier), do: "Build Order"

  defp state_title(:invalid_parameter), do: "Invalid Build Order URL"
  defp state_title(:awaiting_catalog), do: "Loading catalog"
  defp state_title(:catalog_unavailable), do: "Catalog unavailable"
  defp state_title(:catalog_stale), do: "Catalog is stale"
  defp state_title(:not_found), do: "Build Order not found"
  defp state_title(:invalid_catalog), do: "Catalog identity conflict"
  defp state_title(:selected_loading), do: "Loading selected graph"
  defp state_title(:selected_stale), do: "Selected graph is stale"
  defp state_title(_status), do: "Build Order unavailable"

  defp state_message(:invalid_parameter), do: "Use one canonical positive GitHub issue number."
  defp state_message(:awaiting_catalog), do: "Waiting for a validated repository catalog before selecting this root."
  defp state_message(:catalog_unavailable), do: "No validated catalog snapshot can resolve this URL yet."
  defp state_message(:catalog_stale), do: "The last-known-good catalog cannot safely confirm this root."
  defp state_message(:not_found), do: "This Build Order is not in the catalog."
  defp state_message(:invalid_catalog), do: "This link matches more than one repository. Pick a specific one."
  defp state_message(:selected_loading), do: "The exact root is selected; its graph snapshot is loading."

  defp state_message(:selected_stale), do: "The provider is stale and has no selected-root last-known-good snapshot."
  defp state_message(_status), do: "Planning data is temporarily unavailable."

  defp state_role(:invalid_parameter), do: "alert"
  defp state_role(:invalid_catalog), do: "alert"
  defp state_role(_status), do: "status"

  defp positive_generation(%Snapshot{generation: generation}) when is_integer(generation) and generation > 0, do: generation
  defp positive_generation(_snapshot), do: 1

  defp model_summary(%{status: :provider_stale}), do: "Showing the last saved plan while live data catches up."

  defp model_state_title(%{status: :provider_stale}), do: "Stale last-known-good graph"
  defp model_state_title(_model), do: "Build Order state"

  defp model_state_role(_model), do: "status"
end
