defmodule AiurWeb.DashboardLive.Usage do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Aiur.Usage.GroupedScopes
  alias Aiur.Usage.GroupedScopes.Scope
  alias Aiur.UsageAggregate
  alias AiurWeb.EndpointConfig
  alias AiurWeb.FinancialData
  alias AiurWeb.FinancialDataAccess
  alias AiurWeb.OperatorControlCenter.UsageSummaryPresenter

  @usage_summary_flush_ms 250
  @usage_summary_max_age_ms 30_000
  @usage_drill_limit 25
  @usage_drill_dimensions ~w(by_provider by_ticket by_agent_family by_model by_account_generation)a

  # --- DASH-031 authenticated usage and cost summary -----------------------

  # On an authorized mount/reconnect, fetch a bounded snapshot and subscribe to
  # daemon-owned change notifications. A denied connection renders the value-free
  # locked view and never queries, subscribes to, caches, or assigns a protected
  # usage, cost, generation, coverage, tier, or drill-down fact.
  @doc false
  @spec assign_initial_usage_summary(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def assign_initial_usage_summary(socket, connected) do
    socket =
      socket
      |> assign(:usage_summary_source, nil)
      |> assign(:usage_summary_pending, nil)
      |> assign(:usage_summary_flush_scheduled?, false)
      |> assign(:usage_summary_drill, nil)
      |> assign(:usage_summary_drill_trigger, nil)

    case {connected, authorized_context(socket)} do
      {true, {:ok, context}} ->
        _ = safe_usage_subscribe(context)
        refresh_usage_summary(socket, nil)

      {_connected, :locked} ->
        assign_locked_usage_summary(socket)

      {false, {:ok, _context}} ->
        # Authorized but not yet connected: defer the protected fetch to the
        # connected mount and show the bounded loading view.
        assign_usage_view(socket, UsageSummaryPresenter.present(nil))
    end
  end

  # The single capability gate every protected usage call passes through. A
  # locked capability or an absent verified context yields `:locked`; no
  # protected fetch, subscribe, or reload is reachable outside this gate.
  defp authorized_context(socket) do
    capability = Map.get(socket.assigns, :financial_data_capability, %{})

    case {Map.get(capability, :state), FinancialDataAccess.context(socket)} do
      {:authorized, %FinancialDataAccess.Context{} = context} -> {:ok, context}
      _denied -> :locked
    end
  end

  # Fetch (message == nil) or revalidate-and-reload (message from a delivered
  # update) one protected usage snapshot, then present it. An
  # authentication_required result is a hard demotion to locked, never stale LKG.
  defp refresh_usage_summary(socket, message) do
    case authorized_context(socket) do
      {:ok, context} -> apply_usage_summary(socket, fetch_usage_result(socket, context, message))
      :locked -> demote_usage_to_locked(socket)
    end
  end

  defp fetch_usage_result(socket, context, message) do
    case current_run_id(socket) do
      run_id when is_binary(run_id) ->
        {:ok, scope} = Scope.this_run(run_id)
        key = usage_cache_key(scope)
        loader = fn -> load_usage_snapshot(scope) end

        case message do
          nil ->
            FinancialData.fetch_usage_grouping(FinancialData, context, key, @usage_summary_max_age_ms, loader)

          message ->
            FinancialData.reload(FinancialData, context, message, :usage_grouping, key, @usage_summary_max_age_ms, loader)
        end

      _no_run ->
        {:ok, blank_usage_snapshot(:known_empty)}
    end
  rescue
    _error -> {:error, :provider_unavailable}
  catch
    :exit, _reason -> {:error, :provider_unavailable}
  end

  defp apply_usage_summary(socket, {:ok, snapshot}) do
    {source, retained?} = UsageSummaryPresenter.reconcile(socket.assigns.usage_summary_source, snapshot)
    status_source = if retained?, do: snapshot, else: nil

    view =
      UsageSummaryPresenter.present(source,
        retained?: retained?,
        status_source: status_source,
        tier_facts: usage_tier_facts(source)
      )

    socket
    |> assign(:usage_summary_source, source)
    |> assign_usage_view(view)
    |> refresh_open_drill()
  end

  defp apply_usage_summary(socket, {:error, :authentication_required}) do
    demote_usage_to_locked(socket)
  end

  defp apply_usage_summary(socket, {:error, _reason}) do
    # A degraded scope/provider preserves the qualified last-known-good (the
    # presenter retains a same-scope healthy snapshot as stale) and never resets
    # usage or cost to zero.
    apply_usage_summary(socket, {:ok, unavailable_usage_snapshot(usage_scope_public(socket))})
  end

  # A hard demotion: clear every protected assign and render the value-free
  # locked view. Used when a mid-session configuration change revokes access.
  defp demote_usage_to_locked(socket) do
    socket
    |> assign(:usage_summary_source, nil)
    |> assign(:usage_summary_pending, nil)
    |> assign(:usage_summary_drill, nil)
    |> assign(:usage_summary_drill_trigger, nil)
    |> assign_locked_usage_summary()
  end

  defp assign_locked_usage_summary(socket) do
    capability = Map.get(socket.assigns, :financial_data_capability, %{})
    assign_usage_view(socket, UsageSummaryPresenter.locked_view(capability))
  end

  defp assign_usage_view(socket, view) do
    socket
    |> assign(:usage_summary, view)
    |> assign(:usage_summary_announcement, UsageSummaryPresenter.announcement(view))
  end

  # Coalesce bursts of daemon change notifications: keep only the latest pending
  # signal and reload once per debounce window so renders and announcements stay
  # bounded and focus-preserving.
  @doc false
  @spec stash_usage_summary(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def stash_usage_summary(socket, message) do
    socket = assign(socket, :usage_summary_pending, message)

    if socket.assigns.usage_summary_flush_scheduled? do
      socket
    else
      schedule_usage_summary_flush()
      assign(socket, :usage_summary_flush_scheduled?, true)
    end
  end

  @doc false
  @spec flush_usage_summary(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def flush_usage_summary(socket) do
    socket = assign(socket, :usage_summary_flush_scheduled?, false)

    case socket.assigns.usage_summary_pending do
      nil -> socket
      message -> socket |> assign(:usage_summary_pending, nil) |> refresh_usage_summary(message)
    end
  end

  defp schedule_usage_summary_flush do
    case EndpointConfig.get(:usage_summary_flush_timer) do
      timer when is_function(timer, 3) -> timer.(self(), :flush_usage_summary, @usage_summary_flush_ms)
      _other -> Process.send_after(self(), :flush_usage_summary, @usage_summary_flush_ms)
    end
  end

  # The loader runs server-side inside the protected facade; the raw cells never
  # leave the daemon — the grouped-scope layer reduces them to a bounded snapshot
  # before anything reaches the browser.
  defp load_usage_snapshot(scope) do
    UsageAggregate.cells_snapshot() |> GroupedScopes.project(scope, currency: "USD")
  end

  # Scope authority is the current run's opaque identity, never inferred from
  # labels, visible rows, URL text, or active workers. The explicit build scope
  # arrives later from DASH-023; this ticket renders `this_run` only.
  defp current_run_id(socket) do
    case Map.get(socket.assigns, :run_summary_source) do
      %{run: %{id: id}} when is_binary(id) and id != "" -> id
      _other -> nil
    end
  end

  # Fold the scope and the current aggregate generation into the cache key so a
  # new projection generation always misses the bounded authenticated cache.
  defp usage_cache_key(scope) do
    {Scope.public(scope), usage_aggregate_generation()}
  end

  defp usage_aggregate_generation do
    UsageAggregate.snapshot().generation
  rescue
    _error -> :unknown
  catch
    :exit, _reason -> :unknown
  end

  # Tier facts join only on an exact known (provider, backend, generation). The
  # LiveView has no by-generation provider-meter binding today (the meter store
  # is keyed by a live auth binding), so tier facts are empty here and every
  # generation renders explicitly unjoined. The presenter join logic is exercised
  # by fixtures; a by-generation meter seam is future work.
  defp usage_tier_facts(_source), do: %{}

  defp usage_scope_public(socket) do
    case Map.get(socket.assigns, :usage_summary_source) do
      %{scope: scope} when is_map(scope) -> scope
      _other -> %{kind: :this_run, run_id: nil, tickets: [], rejected_tickets: 0, status: :empty}
    end
  end

  # A value-carrying grouped-snapshot shell for the empty and degraded states.
  # Unknown cost is named unknown here, never a synthetic zero total.
  defp blank_usage_snapshot(state) do
    %{
      schema_version: 1,
      state: state,
      scope: %{kind: :this_run, run_id: nil, tickets: [], rejected_tickets: 0, status: :empty},
      currency: "USD",
      tokens: %{},
      provider_reported_estimate: %{by_currency: %{}},
      api_equivalent_estimate: %{rollup: %{}, coverage: %{known: 0, unknown: 0, reasons: [], status: :none}},
      contributors: %{by_auth_mode: []},
      reconciliation: %{reconciled?: true, by_dimension: %{}},
      tier_join_keys: [],
      coverage: %{source: %{}, unknown_attribution: %{}, api_equivalent: %{known: 0, unknown: 0, reasons: [], status: :none}},
      retained_interval: %{earliest: nil, latest: nil, status: :missing},
      health: :healthy,
      freshness: %{status: :empty}
    }
  end

  defp unavailable_usage_snapshot(scope) do
    blank_usage_snapshot(:unavailable)
    |> Map.put(:scope, scope)
    |> Map.put(:health, {:unavailable, :provider_unavailable})
    |> Map.put(:freshness, %{status: :unavailable})
  end

  defp safe_usage_subscribe(context) do
    FinancialData.subscribe(context)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  # Bounded, keyboard/touch drill-down. Only an authorized connection with a
  # loaded snapshot may open or page a dimension; a denied connection is a no-op.
  @doc false
  @spec open_usage_drill(Phoenix.LiveView.Socket.t(), term()) :: term()
  def open_usage_drill(socket, dimension) do
    with {:ok, _context} <- authorized_context(socket),
         dim when not is_nil(dim) <- usage_drill_dimension(dimension),
         %{} = source <- Map.get(socket.assigns, :usage_summary_source) do
      page = UsageSummaryPresenter.drill_down(source, dim, limit: @usage_drill_limit)

      socket
      |> assign(:usage_summary_drill, page)
      |> assign(:usage_summary_drill_trigger, Atom.to_string(dim))
    else
      _denied_or_missing -> socket
    end
  end

  @doc false
  @spec page_usage_drill(Phoenix.LiveView.Socket.t(), term(), term()) :: term()
  def page_usage_drill(socket, dimension, cursor) do
    with {:ok, _context} <- authorized_context(socket),
         dim when not is_nil(dim) <- usage_drill_dimension(dimension),
         %{} = source <- Map.get(socket.assigns, :usage_summary_source),
         %{dimension: ^dim} = existing <- Map.get(socket.assigns, :usage_summary_drill),
         cursor when is_integer(cursor) <- parse_cursor(cursor) do
      page = UsageSummaryPresenter.drill_down(source, dim, cursor: cursor, limit: @usage_drill_limit)
      assign(socket, :usage_summary_drill, %{page | items: existing.items ++ page.items})
    else
      _denied_or_missing -> socket
    end
  end

  # Keep an open drill-down consistent with the current snapshot: when a live
  # update replaces the source, re-page the same dimension over the fresh source
  # for the number of rows already shown, so stale contributor rows never mix
  # with a newer projection.
  defp refresh_open_drill(socket) do
    case {Map.get(socket.assigns, :usage_summary_drill), Map.get(socket.assigns, :usage_summary_source)} do
      {%{dimension: dim} = existing, %{} = source} ->
        shown = max(length(existing.items), @usage_drill_limit)
        page = UsageSummaryPresenter.drill_down(source, dim, cursor: 0, limit: shown)
        assign(socket, :usage_summary_drill, page)

      _no_open_drill ->
        socket
    end
  end

  defp usage_drill_dimension(dimension) when is_binary(dimension) do
    Enum.find(@usage_drill_dimensions, &(Atom.to_string(&1) == dimension))
  end

  defp usage_drill_dimension(_dimension), do: nil

  defp parse_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: cursor

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {value, ""} when value >= 0 -> value
      _other -> nil
    end
  end

  defp parse_cursor(_cursor), do: nil
end
