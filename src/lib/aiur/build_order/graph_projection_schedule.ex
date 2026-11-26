defmodule Aiur.BuildOrder.GraphProjection.Schedule do
  @moduledoc false

  # Scope timers, intervals and the scope-entry accessors they are computed from.
  # Runs inside the projection process: every `self()` here is the GenServer.

  alias Aiur.BuildOrder.GraphProjection.Policy

  # The "bound" fallback when the catalog is on-demand (`planning: 0`, #2309):
  # the tracker's base poll interval, mirroring `Aiur.BuildOrder.Cadence`'s own
  # fallback. On-demand means no *timer*, not zero-width retry backoff or
  # staleness, so a failed read's retry base and a page's displayed staleness
  # fall back to this rather than becoming 0.
  @catalog_on_demand_fallback_ms 120_000

  @spec retry_due?(map(), map()) :: boolean()
  def retry_due?(%{health: health}, state), do: Policy.retry_due?(health, now(state))

  # The catalog schedules no successor. It is event-sourced from the store
  # (#2313): a rebuild is triggered by a `github_resource_changed` store event,
  # by the rare reconciliation, or by an explicit `refresh_catalog/1` — never by
  # a clock. Keeping the old `catalog_refresh_ms` timer here would be a free
  # no-op rebuild of an unchanged store, which is precisely the periodic
  # re-render the ticket removes.
  @spec schedule_after_completion(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}, term()) :: map()
  def schedule_after_completion(state, :catalog, _delay), do: state

  # A selected root never schedules its successor. Completing a read used to
  # queue the next one `graph_selected_refresh_ms` later for as long as anyone
  # was watching, which made an open page a permanent meter — the single most
  # expensive read in Build Order, repeating because of who was looking rather
  # than because anything had changed.
  #
  # What refreshes a selected root now is the daemon's own catalog reconciliation,
  # via the per-root change marker, plus an explicit `refresh/2`. Neither depends
  # on a viewer. A webhook or mutation write to `Aiur.GitHub.ResourceStore` *does*
  # reach here through the store's change events, so a dependency edge set
  # outside Aiur re-reads the root it touches (#2313).
  def schedule_after_completion(state, {:selected, _identity}, _delay), do: state

  # The catalog has no success cadence — it is event-sourced from the store and
  # rebuilt on change (#2313), never on a clock. This clause keeps
  # `schedule_active_scope/2` (which runs on almost every message via
  # `reschedule_active_scopes/1`) from quietly re-arming the old periodic poll.
  defp schedule_from_success(state, :catalog), do: state

  defp schedule_from_success(state, scope) do
    entry = scope_entry(state, scope)

    cond do
      # A zero interval is the on-demand sentinel: the catalog has no cadence, so
      # a successful read arms nothing — the next read is demand-driven (#2309).
      scope_interval(state, scope) == 0 ->
        state

      is_nil(entry) or not is_nil(entry.inflight) or not is_nil(entry.timer) ->
        state

      is_nil(entry.last_success_ms) ->
        state

      true ->
        remaining = max(0, scope_interval(state, scope) - (now_ms(state) - entry.last_success_ms))
        schedule_scope(state, scope, remaining)
    end
  end

  defp schedule_active_scope(state, scope) do
    entry = scope_entry(state, scope)

    cond do
      no_schedule?(state, scope, entry) ->
        state

      is_nil(entry.health.next_retry_at) ->
        schedule_from_success(state, scope)

      retry_due?(entry, state) ->
        schedule_scope(state, scope, 0)

      true ->
        delay = max(0, DateTime.diff(entry.health.next_retry_at, now(state), :millisecond))
        schedule_scope(state, scope, delay)
    end
  end

  # No timer to restore: either the catalog is on-demand (#2309 — a page refresh
  # is demand-driven, so a message must not re-arm the cadence), or the scope is
  # not configured / not active / already scheduled.
  defp no_schedule?(state, scope, entry) do
    (scope == :catalog and catalog_on_demand?(state)) or
      not configuration_ready?(state) or is_nil(entry) or not active_scope?(state, scope) or
      not is_nil(entry.inflight) or not is_nil(entry.timer)
  end

  @spec schedule_scope(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}, integer()) :: map()
  def schedule_scope(state, scope, delay) do
    entry = scope_entry(state, scope)
    entry = cancel_entry_schedule(entry)
    token = state.next_timer_token
    timer = Process.send_after(self(), {:graph_projection_due, scope, token}, max(0, delay))
    entry = %{entry | timer: timer, timer_token: token}

    state
    |> put_scope_entry(entry, scope)
    |> Map.put(:next_timer_token, token + 1)
  end

  # Only the catalog gets a *cadence* restored here. A selected root has none any
  # more, so re-arming one for every watched root — which is what this used to do
  # — would quietly reintroduce the viewer-driven refresh that
  # `schedule_after_completion/3` removes.
  #
  # A selected root's **retry** is a different thing and must survive, because
  # this runs on almost every message: it cancels all timers, so without
  # restoring the retry a root whose read failed would lose its backoff timer to
  # the next unrelated message and never be read again. So a selected scope is
  # re-armed exactly when it is holding a pending retry, and never otherwise.
  @spec reschedule_active_scopes(map()) :: map()
  def reschedule_active_scopes(state) do
    state
    |> cancel_all_timers()
    |> schedule_active_scope(:catalog)
    |> restore_selected_retries()
  end

  defp restore_selected_retries(state) do
    Enum.reduce(state.selected, state, fn {_key, entry}, state ->
      if is_nil(entry.health.next_retry_at),
        do: state,
        else: schedule_active_scope(state, entry.scope)
    end)
  end

  @spec active_scope?(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}) :: boolean()
  def active_scope?(_state, :catalog), do: true

  def active_scope?(state, {:selected, identity}) do
    case Map.get(state.selected, Policy.root_key(identity)) do
      %{demanders: demanders} -> MapSet.size(demanders) > 0
      _entry -> false
    end
  end

  # The catalog's *timer* cadence: `0` when the planning class is on-demand, in
  # which case nothing arms a catalog timer and every read is demand-driven
  # (#2309). The timer-arming call sites guard against `0` directly.
  @spec scope_interval(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}) :: non_neg_integer()
  def scope_interval(state, :catalog), do: state.policy.catalog_refresh_ms

  # A selected root has no refresh interval of its own any more. What remains for
  # it are the two things an interval was still being read for — the base of the
  # failure backoff, and the window after which a snapshot is shown as ageing.
  #
  # Both used to derive from `catalog_refresh_ms`, because the catalog poll was
  # the daemon-owned writer that would next notice this root changing, making it
  # the real bound on how stale the root could be without anyone finding out.
  # The catalog is event-sourced now (#2313): a root's graph is re-read when a
  # store event or the rare reconciliation notices a change, so the honest bound
  # is delivery latency — `webhooks.silence_threshold_seconds`, the gap after
  # which degradation triggers the reconciliation. That is the base a selected
  # root's failure backoff widens from.
  def scope_interval(state, {:selected, _identity}), do: state.policy.delivery_staleness_ms

  # Whether the catalog is on-demand: `polling.intervals.planning: 0` (#2309).
  defp catalog_on_demand?(state), do: state.policy.catalog_refresh_ms == 0

  # A non-zero base for the two "bound" roles a cadence still feeds when the
  # catalog is on-demand: a failed read's retry delay, and the staleness window
  # a page displays. On-demand means *no timer*, not zero-width backoff/staleness,
  # so the bound falls back to the tracker's base poll interval (mirroring
  # `Aiur.BuildOrder.Cadence`'s own fallback) when the cadence is `0`; a real
  # cadence is its own bound.
  @spec catalog_bound_ms(map()) :: pos_integer()
  def catalog_bound_ms(state) do
    case state.policy.catalog_refresh_ms do
      0 -> @catalog_on_demand_fallback_ms
      cadence_ms -> cadence_ms
    end
  end

  # A failed read arms a successor timer only when the scope actually keeps a
  # cadence — an on-demand catalog never does (#2309); selected roots always do
  # (their retry must survive `reschedule_active_scopes`).
  @spec successor_allowed?(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}) :: boolean()
  def successor_allowed?(state, :catalog), do: not catalog_on_demand?(state)
  def successor_allowed?(_state, {:selected, _identity}), do: true

  # The retry base for a failed read. The catalog's own read keeps the planning
  # cadence (or its on-demand fallback) as its base; a selected root's retry is
  # re-based on delivery latency (#2313), because the event-sourced catalog no
  # longer polls on a clock — delivery latency is what bounds how stale the root
  # can be before the reconciliation re-reads it.
  @spec retry_base_ms(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}) :: non_neg_integer()
  def retry_base_ms(state, :catalog), do: catalog_bound_ms(state)
  def retry_base_ms(state, {:selected, _identity}), do: state.policy.delivery_staleness_ms

  @spec scope_entry(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}) :: map() | nil
  def scope_entry(state, :catalog), do: state.catalog

  def scope_entry(state, {:selected, identity}) do
    Map.get(state.selected, Policy.root_key(identity))
  end

  @spec put_scope_entry(map(), map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}) :: map()
  def put_scope_entry(state, entry, :catalog), do: %{state | catalog: entry}

  def put_scope_entry(state, entry, {:selected, identity}) do
    %{state | selected: Map.put(state.selected, Policy.root_key(identity), entry)}
  end

  @spec cancel_all_timers(map()) :: map()
  def cancel_all_timers(state) do
    catalog = cancel_entry_schedule(state.catalog)
    selected = Map.new(state.selected, fn {key, entry} -> {key, cancel_entry_schedule(entry)} end)
    %{state | catalog: catalog, selected: selected}
  end

  @spec cancel_entry_schedule(map()) :: map()
  def cancel_entry_schedule(%{timer: nil} = entry), do: entry

  def cancel_entry_schedule(entry) do
    cancel_entry_timer(entry)
    %{entry | timer: nil}
  end

  @spec cancel_entry_timer(map()) :: term()
  def cancel_entry_timer(%{timer: nil}), do: :ok
  def cancel_entry_timer(%{timer: timer}), do: Process.cancel_timer(timer)

  @spec configuration_ready?(map()) :: boolean()
  def configuration_ready?(%{active_repository: {_, _}, authority_fingerprint: fingerprint, catalog: catalog}) do
    fingerprint != :unknown and catalog.health.failure != :configuration
  end

  def configuration_ready?(_state), do: false

  @spec now(map()) :: DateTime.t()
  def now(state), do: state.now.()
  @spec now_ms(map()) :: integer()
  def now_ms(state), do: state.clock_ms.()
end
