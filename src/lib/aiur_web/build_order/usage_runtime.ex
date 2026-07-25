defmodule AiurWeb.BuildOrder.UsageRuntime do
  @moduledoc """
  Live selected-scope `this build` usage integration for the Build Order route.

  Extends BO-012's selected-route composition with a thin, generation-safe
  adapter that renders DASH-031's protected usage/cost component scoped to the
  exact current GitHub member set (BO-003), read only through the DASH-021
  protected financial-data boundary and the DASH-030 explicit-ticket-set query.

  Invariants this module preserves:

    * A protected fetch, subscription, cache, or assign is reachable only through
      the single `authorized_context/1` capability gate; a locked connection
      renders the value-free locked view and never obtains a usage, cost, tier,
      coverage, or generation fact.
    * A selected-root switch resets the retained snapshot and drill-down before
      anything for the new root renders, so one build's cost can never appear
      under another root's URL.
    * A fetch is scheduled only through the coalescing debounce window, so a burst
      of graph-projection generations or provider updates yields at most one
      protected re-read per window and never a synchronous full projection on the
      render path.
    * A result is renderable only when the membership key at fetch time still
      matches the current selection; `reconcile/2` retains a same-scope healthy
      last-known-good rather than resetting cost to zero, and never carries one
      member set's cost onto another.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Aiur.TrackerIdentity
  alias Aiur.Usage.GroupedScopes
  alias AiurWeb.BuildOrder.{RouteState, UsageScope}
  alias AiurWeb.Endpoint
  alias AiurWeb.FinancialData
  alias AiurWeb.FinancialDataAccess
  alias AiurWeb.OperatorControlCenter.UsageSummaryPresenter
  alias Phoenix.LiveView.Socket

  @flush_ms 250
  @max_age_ms 30_000
  @drill_limit 25
  @drill_dimensions ~w(by_provider by_ticket by_agent_family by_model by_account_generation)a

  @doc "Assigns the initial content-free usage state before any protected read."
  @spec initialize(Socket.t()) :: Socket.t()
  def initialize(socket) do
    socket
    |> assign(:bo_usage_scope, %{state: :none, reason: nil, rejected: 0, graph_health: :ready})
    |> assign(:bo_usage_view, nil)
    |> assign(:bo_usage_announcement, nil)
    |> assign(:bo_usage_source, nil)
    |> assign(:bo_usage_pending, nil)
    |> assign(:bo_usage_flush_scheduled?, false)
    |> assign(:bo_usage_key, nil)
    |> assign(:bo_usage_identity, nil)
    |> assign(:bo_usage_drill, nil)
    |> assign(:bo_usage_drill_trigger, nil)
  end

  @doc """
  On a connected mount/reconnect, subscribe to protected accounting/meter changes
  when authorized, then reconcile the region with the current selection.
  """
  @spec connect(Socket.t()) :: Socket.t()
  def connect(socket) do
    case authorized_context(socket) do
      {:ok, context} ->
        _ = safe_subscribe(context)
        sync_scope(socket)

      :locked ->
        sync_scope(socket)
    end
  end

  @doc """
  Re-derive the scope decision after any route-state change and reconcile the
  region. Resets the retained snapshot/drill on a selected-root switch, renders
  the immediate scope-level state, and schedules one debounced protected re-read
  when the current member set needs fresh accounting.
  """
  @spec sync_scope(Socket.t()) :: Socket.t()
  def sync_scope(socket) do
    decision = UsageScope.decide(socket.assigns.route_state)

    socket
    |> reset_on_identity_change(current_identity(socket.assigns.route_state))
    |> reconcile_decision(decision)
  end

  @doc "Coalesce a payload-free protected update; reload once per debounce window."
  @spec stash(Socket.t(), term()) :: Socket.t()
  def stash(socket, message), do: schedule_refresh(socket, message)

  @doc "Flush a coalesced protected re-read for the current selection."
  @spec flush(Socket.t()) :: Socket.t()
  def flush(socket) do
    socket = assign(socket, :bo_usage_flush_scheduled?, false)

    case socket.assigns.bo_usage_pending do
      nil -> socket
      pending -> socket |> assign(:bo_usage_pending, nil) |> refresh(refresh_message(pending))
    end
  end

  @doc "Open a bounded, keyboard/touch drill-down over the retained snapshot."
  @spec open_drill(Socket.t(), term()) :: Socket.t()
  def open_drill(socket, dimension) do
    with {:ok, _context} <- authorized_context(socket),
         dim when not is_nil(dim) <- drill_dimension(dimension),
         %{} = source <- socket.assigns.bo_usage_source do
      page = UsageSummaryPresenter.drill_down(source, dim, limit: @drill_limit)

      socket
      |> assign(:bo_usage_drill, page)
      |> assign(:bo_usage_drill_trigger, Atom.to_string(dim))
    else
      _denied_or_missing -> socket
    end
  end

  @doc "Page the next bounded window of an open drill-down."
  @spec page_drill(Socket.t(), term(), term()) :: Socket.t()
  def page_drill(socket, dimension, cursor) do
    with {:ok, _context} <- authorized_context(socket),
         dim when not is_nil(dim) <- drill_dimension(dimension),
         %{} = source <- socket.assigns.bo_usage_source,
         %{dimension: ^dim} = existing <- socket.assigns.bo_usage_drill,
         cursor when is_integer(cursor) <- parse_cursor(cursor) do
      page = UsageSummaryPresenter.drill_down(source, dim, cursor: cursor, limit: @drill_limit)
      assign(socket, :bo_usage_drill, %{page | items: existing.items ++ page.items})
    else
      _denied_or_missing -> socket
    end
  end

  @doc "Close an open drill-down."
  @spec close_drill(Socket.t()) :: Socket.t()
  def close_drill(socket) do
    socket
    |> assign(:bo_usage_drill, nil)
    |> assign(:bo_usage_drill_trigger, nil)
  end

  # --- decision reconciliation ---------------------------------------------

  defp reconcile_decision(socket, :none) do
    socket
    |> put_scope(:none)
    |> assign(:bo_usage_view, nil)
    |> assign(:bo_usage_announcement, nil)
  end

  defp reconcile_decision(socket, :pending), do: scope_only(socket, :pending)
  defp reconcile_decision(socket, {:invalid, reason}), do: scope_only(socket, :invalid, reason: reason)

  defp reconcile_decision(socket, {:unavailable, reason}),
    do: scope_only(socket, :graph_unavailable, reason: reason)

  defp reconcile_decision(socket, :empty_build), do: scope_only(socket, :empty_build)

  defp reconcile_decision(socket, {:unscopable, rejected}),
    do: scope_only(socket, :unscopable, rejected: rejected)

  defp reconcile_decision(socket, {:ready, _scope, key, graph_health}) do
    socket = put_scope(socket, :ready, graph_health: graph_health)

    cond do
      key == socket.assigns.bo_usage_key and not is_nil(socket.assigns.bo_usage_source) ->
        # Same member set and accounting already loaded: keep the current view.
        socket

      is_nil(socket.assigns.bo_usage_view) ->
        # No accounting shown yet for this selection: show the bounded loading
        # view and schedule the protected read.
        socket
        |> assign_usage_view(loading_view())
        |> schedule_refresh(:scope)

      true ->
        # Member set changed for the same root: keep the last view until the
        # scheduled re-read replaces it, so nothing flickers to zero.
        schedule_refresh(socket, :scope)
    end
  end

  # A non-`:ready` decision renders a distinct scope-level state and never a
  # zero-valued accounting body. Any retained snapshot/drill was already dropped
  # by `reset_on_identity_change/2` on the switch into this state.
  defp scope_only(socket, state, opts \\ []) do
    socket
    |> put_scope(state, opts)
    |> assign(:bo_usage_view, nil)
    |> assign(:bo_usage_announcement, nil)
  end

  defp put_scope(socket, state, opts \\ []) do
    scope = %{
      state: state,
      reason: Keyword.get(opts, :reason),
      rejected: Keyword.get(opts, :rejected, 0),
      graph_health: Keyword.get(opts, :graph_health, :ready)
    }

    assign(socket, :bo_usage_scope, scope)
  end

  # --- protected fetch + present -------------------------------------------

  # Fetch (or revalidate-and-reload) one protected snapshot for the current
  # `this build` scope, then present it. Re-derives the scope at call time so a
  # root switch or membership change between scheduling and flushing can never
  # render a stale member set's cost.
  defp refresh(socket, message) do
    case {authorized_context(socket), UsageScope.decide(socket.assigns.route_state)} do
      {{:ok, context}, {:ready, scope, key, graph_health}} ->
        socket
        |> put_scope(:ready, graph_health: graph_health)
        |> apply_result(fetch_result(context, scope, key, message), scope, key)

      {:locked, _decision} ->
        demote_to_locked(socket)

      {_context, decision} ->
        # No longer a ready scope (e.g. navigated away mid-window): render the
        # current scope-level state without a protected read.
        reconcile_decision(socket, decision)
    end
  end

  defp fetch_result(context, scope, key, message) do
    loader = fn -> load_snapshot(scope) end
    cache_key = cache_key(key, scope)

    case message do
      :scope ->
        FinancialData.fetch_usage_grouping(FinancialData, context, cache_key, @max_age_ms, loader)

      financial_message ->
        FinancialData.reload(
          FinancialData,
          context,
          financial_message,
          :usage_grouping,
          cache_key,
          @max_age_ms,
          loader
        )
    end
  rescue
    _error -> {:error, :provider_unavailable}
  catch
    :exit, _reason -> {:error, :provider_unavailable}
  end

  defp apply_result(socket, {:ok, snapshot}, _scope, key) do
    {source, retained?} = UsageSummaryPresenter.reconcile(socket.assigns.bo_usage_source, snapshot)
    status_source = if retained?, do: snapshot, else: nil

    view =
      UsageSummaryPresenter.present(source,
        retained?: retained?,
        status_source: status_source,
        tier_facts: tier_facts(source)
      )

    socket
    |> assign(:bo_usage_source, source)
    |> assign(:bo_usage_key, key)
    |> assign_usage_view(view)
    |> refresh_open_drill()
  end

  defp apply_result(socket, {:error, :authentication_required}, _scope, _key),
    do: demote_to_locked(socket)

  defp apply_result(socket, {:error, _reason}, scope, key) do
    # A degraded provider preserves the same-scope healthy last-known-good (the
    # presenter retains it as stale) and never resets cost to zero.
    apply_result(socket, {:ok, unavailable_snapshot(scope)}, scope, key)
  end

  # The loader runs server-side inside the protected facade; raw cells never leave
  # the daemon — the grouped-scope layer reduces them to a bounded snapshot.
  defp load_snapshot(scope) do
    GroupedScopes.project(source_snapshot(), scope, currency: "USD")
  end

  defp source_snapshot, do: Aiur.UsageAggregate.cells_snapshot()

  # Fold the member identity set, the selected-root authority epoch, and the
  # accounting generation into the cache key. `this run` and `this build` differ
  # by scope kind, so they can never collide.
  defp cache_key({scope_public, authority_epoch}, _scope) do
    {scope_public, authority_epoch, usage_aggregate_generation()}
  end

  defp usage_aggregate_generation do
    Aiur.UsageAggregate.snapshot().generation
  rescue
    _error -> :unknown
  catch
    :exit, _reason -> :unknown
  end

  # Tier facts join only on an exact known (provider, backend, generation). No
  # by-generation provider-meter binding exists yet (matching DashboardLive), so
  # every generation renders explicitly unjoined rather than guessed.
  defp tier_facts(_source), do: %{}

  # --- coalescing + scheduling ---------------------------------------------

  defp schedule_refresh(socket, message) do
    socket = assign(socket, :bo_usage_pending, prefer_message(socket.assigns.bo_usage_pending, message))

    if socket.assigns.bo_usage_flush_scheduled? do
      socket
    else
      schedule_flush()
      assign(socket, :bo_usage_flush_scheduled?, true)
    end
  end

  # A real protected-update message wins over the `:scope` re-derive sentinel so
  # the flush revalidates the delivered identity when one is pending.
  defp prefer_message(_current, message) when is_tuple(message), do: message
  defp prefer_message(current, :scope) when is_tuple(current), do: current
  defp prefer_message(_current, :scope), do: :scope

  defp refresh_message(:scope), do: :scope
  defp refresh_message(message), do: message

  defp schedule_flush do
    case Endpoint.config(:bo_usage_flush_timer) do
      timer when is_function(timer, 3) -> timer.(self(), :flush_bo_usage, @flush_ms)
      _other -> Process.send_after(self(), :flush_bo_usage, @flush_ms)
    end
  end

  # --- identity reset ------------------------------------------------------

  # On a selected-root switch (or leaving the selected route), drop every retained
  # protected fact and open drill-down so nothing from the prior root can render.
  defp reset_on_identity_change(socket, identity) do
    if identity == socket.assigns.bo_usage_identity do
      socket
    else
      socket
      |> assign(:bo_usage_identity, identity)
      |> assign(:bo_usage_source, nil)
      |> assign(:bo_usage_view, nil)
      |> assign(:bo_usage_announcement, nil)
      |> assign(:bo_usage_key, nil)
      |> assign(:bo_usage_drill, nil)
      |> assign(:bo_usage_drill_trigger, nil)
    end
  end

  defp current_identity(route_state) do
    case RouteState.selected_identity(route_state) do
      %TrackerIdentity{} = identity -> TrackerIdentity.github_key(identity)
      _none -> nil
    end
  end

  # --- drill helpers -------------------------------------------------------

  defp refresh_open_drill(socket) do
    case {socket.assigns.bo_usage_drill, socket.assigns.bo_usage_source} do
      {%{dimension: dim} = existing, %{} = source} ->
        shown = max(length(existing.items), @drill_limit)
        page = UsageSummaryPresenter.drill_down(source, dim, cursor: 0, limit: shown)
        assign(socket, :bo_usage_drill, page)

      _no_open_drill ->
        socket
    end
  end

  defp drill_dimension(dimension) when is_binary(dimension),
    do: Enum.find(@drill_dimensions, &(Atom.to_string(&1) == dimension))

  defp drill_dimension(_dimension), do: nil

  defp parse_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: cursor

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {value, ""} when value >= 0 -> value
      _other -> nil
    end
  end

  defp parse_cursor(_cursor), do: nil

  # --- capability gate + views ---------------------------------------------

  defp authorized_context(socket) do
    capability = Map.get(socket.assigns, :financial_data_capability, %{})

    case {Map.get(capability, :state), FinancialDataAccess.context(socket)} do
      {:authorized, %FinancialDataAccess.Context{} = context} -> {:ok, context}
      _denied -> :locked
    end
  end

  defp demote_to_locked(socket) do
    capability = Map.get(socket.assigns, :financial_data_capability, %{})

    socket
    |> assign(:bo_usage_source, nil)
    |> assign(:bo_usage_key, nil)
    |> assign(:bo_usage_drill, nil)
    |> assign(:bo_usage_drill_trigger, nil)
    |> put_scope(:ready)
    |> assign_usage_view(UsageSummaryPresenter.locked_view(capability))
  end

  defp assign_usage_view(socket, view) do
    socket
    |> assign(:bo_usage_view, view)
    |> assign(:bo_usage_announcement, UsageSummaryPresenter.announcement(view))
  end

  defp loading_view, do: UsageSummaryPresenter.present(nil)

  defp safe_subscribe(context) do
    FinancialData.subscribe(context)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  # A value-carrying grouped-snapshot shell for the degraded state. Unknown cost
  # is named unknown, never a synthetic zero total.
  defp unavailable_snapshot(scope) do
    %{
      schema_version: 1,
      state: :unavailable,
      scope: GroupedScopes.Scope.public(scope),
      currency: "USD",
      tokens: %{},
      provider_reported_estimate: %{by_currency: %{}},
      api_equivalent_estimate: %{rollup: %{}, coverage: %{known: 0, unknown: 0, reasons: [], status: :none}},
      contributors: %{by_auth_mode: []},
      reconciliation: %{reconciled?: true, by_dimension: %{}},
      tier_join_keys: [],
      coverage: %{
        source: %{},
        unknown_attribution: %{},
        api_equivalent: %{known: 0, unknown: 0, reasons: [], status: :none}
      },
      retained_interval: %{earliest: nil, latest: nil, status: :missing},
      health: {:unavailable, :provider_unavailable},
      freshness: %{status: :unavailable}
    }
  end
end
