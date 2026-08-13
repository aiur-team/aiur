defmodule AiurWeb.OperatorControlCenter.BuildOrderSelected do
  @moduledoc "Selected-root state and graph surface for Build Order routes."

  use Phoenix.Component

  alias Aiur.BuildOrder.Diagnostic
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

    assigns =
      assign(assigns, :show_panes?, is_nil(assigns.graph_failure) and not is_nil(assigns.model))

    ~H"""
    <section class="bo-surface" aria-labelledby="build-order-details-title">
      <h2 id="build-order-details-title" class="sr-only">Build Order details</h2>
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

      <div :if={is_nil(@graph_failure) and is_nil(@model) and @status == :selected_loading} class="bo-loading" role="status" aria-live="polite">
        <span class="sr-only">Loading selected graph</span>
        <div class="bo-shimmer bo-shimmer-lede" aria-hidden="true"></div>
        <div class="bo-shimmer-metrics" aria-hidden="true">
          <div :for={_metric <- 1..5} class="bo-shimmer bo-shimmer-metric"></div>
        </div>
        <div class="bo-shimmer-grid" aria-hidden="true">
          <div :for={_card <- 1..8} class="bo-shimmer bo-shimmer-card"></div>
        </div>
      </div>

      <div :if={is_nil(@graph_failure) and is_nil(@model) and @status != :selected_loading} class="bo-state-card" role={state_role(@status)}>
        <h3>{state_title(@status)}</h3>
        <p>{state_message(@status)}</p>
      </div>

      <div :if={@show_panes?} class="bo-selected-summary">
        <p :if={root_title(@snapshot)} class="bo-selected-lede">{root_title(@snapshot)}</p>
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

        <ul :if={@model.diagnostics != []} class="bo-diagnostics" aria-label="Build Order diagnostics">
          <li :for={diagnostic <- @model.diagnostics}>{diagnostic.text}</li>
        </ul>
      </div>

      <section :if={@show_panes? and @model.nodes != []} class="section-card bo-graph-pane">
        <BuildOrderGraph.build_order_graph
          id="selected-build-order-graph"
          root_id={RouteState.root_identifier(@route_state)}
          provider_generation={positive_generation(@snapshot)}
          dom_generation={max(RouteState.dom_generation(@route_state), 1)}
          model={@model}
          adhoc={@adhoc}
        />
      </section>

      <section :if={@show_panes? and @model.status != :empty} class="section-card bo-breakdown-pane">
        <BuildOrderBreakdown.build_order_breakdown model={@model} adhoc={@adhoc} />
      </section>

      <section :if={@show_panes? and @model.status != :empty} class="section-card bo-analytics-pane">
        <BuildOrderAnalytics.build_order_analytics
          scope={@analytics_scope}
          model={@analytics_model}
          unavailable={@analytics_unavailable}
          loading={@analytics_loading}
          time_domain={@time_domain}
        >
          <BuildOrderUsage.build_order_usage
            scope={@usage_scope}
            view={@usage_view}
            announcement={@usage_announcement}
            drill_down={@usage_drill_down}
            drill_trigger={@usage_drill_trigger}
          />
        </BuildOrderAnalytics.build_order_analytics>
      </section>
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
          kind: kind,
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
  defp failure_code(model, snapshot, :unfetched),
    do: first_code([health_failure(model), snapshot_failure(snapshot)], :provider_unavailable)

  # A structural verdict may only be sourced from structure. Producers that fail
  # closed on a structural defect deliberately mark provider health failed, and
  # `SelectedRoot.availability/2` states that "that marking must not be read as
  # an outage". Reading health here named `rate_limited` as the reason a fetched
  # graph was malformed and sent the debug prompt after the wrong problem.
  defp failure_code(model, _snapshot, :malformed),
    do: first_code([structural_failure(model)], :structurally_invalid)

  defp first_code(candidates, default), do: Enum.find(candidates, default, &(is_atom(&1) and not is_nil(&1)))

  defp health_failure(%{planning_health: %{failure: failure}}) when is_atom(failure), do: failure
  defp health_failure(_model), do: nil

  defp snapshot_failure(%Snapshot{health: %{failure: failure}}) when is_atom(failure), do: failure
  defp snapshot_failure(_snapshot), do: nil

  # The defect the read actually observed. A provider-sourced diagnostic says
  # "we could not fetch this", never "this is malformed", so it can never be the
  # reported fault for a structural verdict.
  defp structural_failure(%{diagnostics: diagnostics}) when is_list(diagnostics) do
    diagnostics
    |> Enum.filter(&match?(%Diagnostic{}, &1))
    |> Enum.reject(&Diagnostic.provider_sourced?/1)
    |> Enum.map(& &1.code)
    |> Enum.filter(&is_atom/1)
    |> Enum.sort()
    |> List.first()
  end

  defp structural_failure(_model), do: nil

  defp failure(:unfetched, context) do
    %{
      role: "status",
      code: context.code,
      title: "Could not fetch planning graph",
      message: "The selected-root provider did not return a graph, so its counts and dependent views are unavailable.",
      prompt:
        "Investigate why #{root_label(context.identifier)}'s planning graph could not be fetched. " <>
          "The selected-root provider reports `#{context.code}`#{scope_suffix(context.snapshot)}; " <>
          "graph counts are unresolved#{diagnostic_suffix(context)}."
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
          "#{member_observation(context.model)}#{diagnostic_suffix(context)}."
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

  # No resolved count was read, so there is no observation to add. The card's own
  # message already states the structural verdict, and repeating it here would be
  # the restatement this state exists to remove.
  defp member_observation(_model), do: ""

  # Only genuinely distinct faults earn a mention. A diagnostic that restates the
  # reported fault is the same fact twice, which is the defect this state fixes.
  defp diagnostic_suffix(%{model: %{diagnostics: diagnostics}, code: code, kind: kind}) when is_list(diagnostics) do
    codes =
      diagnostics
      |> Enum.map(&Map.get(&1, :code))
      |> Enum.filter(&is_atom/1)
      |> Enum.reject(&restates?(&1, code, kind))
      |> Enum.uniq()
      |> Enum.sort()

    case codes do
      [] -> ""
      codes -> "; also reported: " <> Enum.map_join(codes, ", ", &"`#{&1}`")
    end
  end

  defp diagnostic_suffix(_context), do: ""

  defp restates?(code, code, _kind), do: true

  # `:provider_unavailable` is the generic label a fetch fault launders into, so
  # beside a specific fetch fault it is the same outage said twice. Beside a
  # structural verdict it is a second, genuinely distinct fault: the graph is
  # malformed *and* the provider is down. Dropping it there would hide a fault.
  defp restates?(:provider_unavailable, _code, :unfetched), do: true
  defp restates?(_diagnostic_code, _code, _kind), do: false

  # The header carries only "Build Order #<n>", so the root's own name has to
  # render here or a bookmarked detail page never says which Build Order it is.
  # An unresolved root has no name to state, and inventing one would be a lie.
  defp root_title(%Snapshot{data: %SelectedRoot{root: %{title: title}}}) when is_binary(title) do
    case title |> String.trim() |> strip_bo_prefix() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp root_title(_snapshot), do: nil

  # Build Order issues are often titled with a leading "BO:" tag. The dashboard
  # renders the title as a page lede, where the tag is noise the operator
  # already knows from context — strip it (case-insensitively) here only, never
  # from the underlying root data.
  defp strip_bo_prefix(title) do
    String.replace(title, ~r/^BO\s*:\s*/i, "", global: false)
  end

  # An unresolved graph has no counts to show. Rendering the zeros of an empty
  # model would state a number we never read — "Unresolved" is the honest cell.
  defp metric(%{resolved?: false}, _value), do: "Unresolved"
  defp metric(_summary, value), do: value

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
