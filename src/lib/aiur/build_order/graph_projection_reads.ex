defmodule Aiur.BuildOrder.GraphProjection.Reads do
  @moduledoc false

  # Scope read requests: admission, task start, completion and the per-root change marker.
  # Runs inside the projection process: every `self()` here is the GenServer.

  alias Aiur.BuildOrder.Catalog
  alias Aiur.BuildOrder.GraphProjection.{CatalogCounts, Policy, Publication, Resources, Schedule, TaskLifecycle}

  @spec request_scope(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}, keyword()) :: {map(), [tuple()]}
  def request_scope(state, scope, opts \\ []) do
    entry = Schedule.scope_entry(state, scope)
    forced? = forced_request?(state, scope, opts)

    cond do
      not Schedule.configuration_ready?(state) ->
        {state, []}

      is_nil(entry) ->
        {state, []}

      # A read is already running. Whether that satisfies this request depends on
      # *which world it is reading*, so the two cases are separated rather than
      # both being dropped.
      #
      # Same marker: the inflight read was dispatched against the catalog
      # observation this request is about, so it will answer it. Coalesce — this
      # is what makes ten simultaneous callers produce one read.
      #
      # Different marker: the inflight read was dispatched against an older
      # catalog and cannot answer this request, so dropping it is a lost update —
      # the read lands, stamps its own (older) marker, and nothing is left to
      # notice the newer one. Queue it; `admit_pending/1` starts it as soon as the
      # inflight read finishes.
      entry.inflight ->
        {join_inflight(state, entry, scope, forced?), []}

      # "Nobody is watching" is the right answer to an *inferred* request and
      # the wrong one to a stated need. A root can be held — its entry, its
      # graph and its markers all retained — without a live page registered on
      # it, and an operator asking for that root to be read now was being told
      # nothing at all (#2538). A forced request reads what is held; it still
      # cannot conjure an entry that does not exist, which is what stops a
      # caller buying a read for a root the projection is not keeping.
      not forced? and not Schedule.active_scope?(state, scope) ->
        {state, []}

      map_size(state.inflight_by_ref) >= state.policy.max_inflight ->
        {defer_scope(state, scope, forced?), []}

      true ->
        start_scope(state, entry, scope)
    end
  end

  # Forcing survives being queued: a forced request that had to wait for the
  # inflight read is still forced when `admit_pending/1` re-offers it, or it
  # would be dropped again by the very check it was meant to bypass.
  defp forced_request?(state, scope, opts) do
    Keyword.get(opts, :force?, false) or MapSet.member?(state.forced, scope)
  end

  defp join_inflight(state, entry, scope, forced?) do
    if inflight_satisfies?(entry.inflight, state, scope),
      do: state,
      else: defer_scope(state, scope, forced?)
  end

  defp defer_scope(state, scope, forced?) do
    %{
      state
      | pending: MapSet.put(state.pending, scope),
        forced: if(forced?, do: MapSet.put(state.forced, scope), else: state.forced)
    }
  end

  defp start_scope(state, entry, scope) do
    entry = Schedule.cancel_entry_schedule(entry)
    now = Schedule.now(state)
    entry = Policy.refreshing(entry, now)
    attempt = state.next_attempt
    member_labels? = CatalogCounts.catalog_labels_due?(state, scope)
    reader_options = reader_options(state, member_labels?)

    case TaskLifecycle.start(state, scope, reader_options) do
      {:ok, task} ->
        timeout_ref =
          Process.send_after(self(), {:graph_projection_timeout, task.ref, attempt}, state.policy.refresh_timeout_ms)

        inflight = %{
          ref: task.ref,
          pid: task.pid,
          timeout_ref: timeout_ref,
          scope: scope,
          attempt: attempt,
          member_labels?: member_labels?,
          # The catalog marker in force when this read was *dispatched*, not when
          # it lands. Stamping the completion-time marker is a lost update: a read
          # dispatched against F1 can complete after a catalog cycle has published
          # F2, and stamping F2 onto F1-era data marks the root current at a state
          # it has never held — after which nothing ever re-reads it.
          catalog_fingerprint: requested_fingerprint(state, scope),
          authority_generation: state.authority_generation,
          configuration_generation: state.active_configuration_generation
        }

        entry = %{entry | inflight: inflight}

        state =
          state
          |> Schedule.put_scope_entry(entry, scope)
          |> Resources.clear_member_due(scope)
          |> Map.put(:next_attempt, attempt + 1)
          |> Map.put(:inflight_by_ref, Map.put(state.inflight_by_ref, task.ref, inflight))
          |> Map.put(:pending, MapSet.delete(state.pending, scope))
          # The forced request is being served by this read, so it is spent.
          |> Map.put(:forced, MapSet.delete(state.forced, scope))

        {state, [{:health, Publication.snapshot_for_entry(entry, state)}]}

      :error ->
        fail_scope_start(state, entry, scope, now)
    end
  end

  defp fail_scope_start(state, entry, scope, now) do
    scheduled? = Schedule.active_scope?(state, scope)
    delay = Policy.retry_delay_ms(entry.health.retry_count, Schedule.retry_base_ms(state, scope), nil, now)
    next_retry_at = DateTime.add(now, delay, :millisecond)
    entry = Policy.apply_failure(entry, :transport, now, next_retry_at, scheduled?)
    state = Schedule.put_scope_entry(state, entry, scope)
    state = if(scheduled? and Schedule.successor_allowed?(state, scope), do: Schedule.schedule_scope(state, scope, delay), else: state)
    {state, [{:health, Publication.snapshot_for_entry(Schedule.scope_entry(state, scope), state)}]}
  end

  @spec complete_task(map(), reference(), term()) :: {map(), [tuple()]}
  def complete_task(state, ref, result) do
    case Map.pop(state.inflight_by_ref, ref) do
      {nil, _inflight_by_ref} ->
        {state, []}

      {%{scope: scope} = inflight, inflight_by_ref} ->
        Process.cancel_timer(inflight.timeout_ref)
        state = %{state | inflight_by_ref: inflight_by_ref}
        complete_scope(state, scope, inflight, result)
    end
  end

  defp complete_scope(state, scope, inflight, result) do
    case Schedule.scope_entry(state, scope) do
      %{inflight: %{ref: ref}} = entry
      when ref == inflight.ref and inflight.authority_generation == state.authority_generation and
             inflight.configuration_generation == state.active_configuration_generation ->
        case Policy.complete_candidate(result, scope, state.active_repository) do
          {:ok, candidate} ->
            complete_success(state, entry, scope, candidate, inflight)

          {:error, failure, provider_result} ->
            state
            |> CatalogCounts.record_catalog_labels_failure(scope, inflight, failure, provider_result)
            |> complete_failure(entry, scope, failure, provider_result)
        end

      _entry ->
        discard_obsolete_completion(state, scope, inflight.ref)
    end
  end

  defp discard_obsolete_completion(state, scope, ref) do
    case Schedule.scope_entry(state, scope) do
      %{inflight: %{ref: ^ref}} = entry ->
        entry = %{entry | inflight: nil, health: %{entry.health | refreshing?: false}}
        state = Schedule.put_scope_entry(state, entry, scope)
        request_scope(state, scope)

      _entry ->
        {state, []}
    end
  end

  defp complete_success(state, entry, scope, candidate, inflight) do
    generation = state.next_generation
    candidate = CatalogCounts.carry_catalog_counts(state, candidate, entry, scope, inflight)
    {state, candidate} = CatalogCounts.put_catalog_count_resolution(state, candidate, scope, inflight)
    entry = Policy.apply_success(entry, candidate, generation, Schedule.now(state), Schedule.now_ms(state))

    state =
      state
      |> Schedule.put_scope_entry(entry, scope)
      |> Map.put(:next_generation, generation + 1)
      |> CatalogCounts.record_catalog_labels_read(scope, inflight)

    state = Schedule.schedule_after_completion(state, scope, state |> Schedule.scope_interval(scope))
    state = record_selected_fingerprint(state, scope, inflight)
    events = [{:generation, Publication.snapshot_for_entry(Schedule.scope_entry(state, scope), state)}]

    {state, follow_up} = request_changed_selected_roots(state, scope)
    {state, events ++ follow_up}
  end

  # A selected root's graph is read because the catalog — the one daemon-owned
  # reader left — says the root moved, or because nothing has ever been read for
  # a root somebody is watching. Both are writer-driven: neither depends on how
  # long a page stays open, and neither repeats while the root sits still.
  #
  # Only a *catalog* completion reaches this. A selected completion must not, or
  # a root would refresh itself forever.
  defp request_changed_selected_roots(state, :catalog) do
    state.selected
    |> Enum.filter(fn {_key, entry} -> selected_read_due?(state, entry) end)
    |> Enum.reduce({state, []}, fn {_key, entry}, {state, events} ->
      {state, next_events} = request_scope(state, entry.scope)
      {state, events ++ next_events}
    end)
  end

  defp request_changed_selected_roots(state, _scope), do: {state, []}

  # "Is anybody watching?" is deliberately not asked here. `request_scope/2`
  # already declines a scope that is not active, and for a selected root that
  # means `demanders` is empty — so a root that was selected and then released
  # keeps its entry and buys nothing. Repeating the check here would be a second
  # copy of that rule, free to drift from the one that is actually enforced.
  defp selected_read_due?(state, entry) do
    cond do
      # A demanded root that has never been read is the cold case. It is bought
      # once, on the catalog's cycle rather than on the viewer's, and it does not
      # repeat once it succeeds. Backoff still applies, so a root that fails to
      # read does not retry on every catalog poll.
      is_nil(entry.data) -> Schedule.retry_due?(entry, state)
      # Otherwise: only a root the catalog says has moved.
      selected_fingerprint_moved?(state, entry) -> Schedule.retry_due?(entry, state)
      true -> false
    end
  end

  # A `nil` *current* marker means the catalog has nothing to compare against,
  # which is not evidence of change. Treating it as change would make every
  # catalog poll re-read every watched root — the deleted cadence back again,
  # wearing the writer's clothes.
  #
  # A `nil` *recorded* marker is the opposite case and must not be folded into
  # it. It means this graph was read at a moment the catalog held no marker for
  # the root — the ordinary poll-only boot, where the store is empty until the
  # reconciliation's deposits land — so the read corresponds to no catalog
  # observation at all. Answering `false` there froze the root permanently:
  # nothing else moves the recorded marker, so the entry could never become due
  # again and only an explicit `refresh/2` ever re-read it (#2608). Answering
  # `true` costs one read, after which the completion stamps a real marker and
  # the root goes quiet again.
  @spec selected_fingerprint_moved?(map(), map()) :: boolean()
  def selected_fingerprint_moved?(state, %{scope: {:selected, identity}}) do
    case {catalog_fingerprint(state, identity), Map.get(state.selected_fingerprints, Policy.root_key(identity))} do
      {nil, _recorded} -> false
      {_current, nil} -> true
      {current, recorded} -> current != recorded
    end
  end

  def selected_fingerprint_moved?(_state, _entry), do: false

  defp catalog_fingerprint(%{catalog: %{data: %Catalog{} = catalog}}, identity),
    do: Catalog.root_fingerprint(catalog, identity)

  defp catalog_fingerprint(_state, _identity), do: nil

  # Stamped from the marker captured when the read was dispatched, carried on the
  # inflight record. It records which catalog observation this graph actually
  # corresponds to, which is the only claim the data supports.
  defp record_selected_fingerprint(state, {:selected, identity}, inflight) do
    key = Policy.root_key(identity)

    case Map.get(inflight, :catalog_fingerprint) do
      nil -> %{state | selected_fingerprints: Map.delete(state.selected_fingerprints, key)}
      fingerprint -> %{state | selected_fingerprints: Map.put(state.selected_fingerprints, key, fingerprint)}
    end
  end

  defp record_selected_fingerprint(state, _scope, _inflight), do: state

  defp requested_fingerprint(state, :catalog), do: state.catalog_change_seq
  defp requested_fingerprint(state, {:selected, identity}), do: catalog_fingerprint(state, identity)

  defp inflight_satisfies?(inflight, state, scope) do
    Map.get(inflight, :catalog_fingerprint) == requested_fingerprint(state, scope)
  end

  defp complete_failure(state, entry, scope, failure, provider_result) do
    now = Schedule.now(state)
    scheduled? = Schedule.active_scope?(state, scope)
    delay = Policy.retry_delay_ms(entry.health.retry_count, Schedule.retry_base_ms(state, scope), provider_result, now)
    next_retry_at = DateTime.add(now, delay, :millisecond)
    entry = Policy.apply_failure(entry, failure, now, next_retry_at, true)
    state = Schedule.put_scope_entry(state, entry, scope)
    state = if(scheduled? and Schedule.successor_allowed?(state, scope), do: Schedule.schedule_scope(state, scope, delay), else: state)
    {state, [{:health, Publication.snapshot_for_entry(Schedule.scope_entry(state, scope), state)}]}
  end

  @spec admit_pending(map()) :: {map(), [tuple()]}
  def admit_pending(state) do
    Enum.reduce_while(state.pending, {state, []}, fn scope, {state, events} ->
      if map_size(state.inflight_by_ref) < state.policy.max_inflight do
        {state, next_events} = request_scope(state, scope)
        {:cont, {state, events ++ next_events}}
      else
        {:halt, {state, events}}
      end
    end)
  end

  @spec reader_options(map(), boolean()) :: keyword()
  def reader_options(state, member_labels?) do
    [
      repository: state.active_repository,
      root_limit: state.root_limit,
      page_budget: state.page_budget,
      call_budget: state.call_budget,
      member_labels: member_labels?
    ]
  end

  @spec cancel_all_tasks(map()) :: map()
  def cancel_all_tasks(state) do
    Enum.each(state.inflight_by_ref, fn {ref, inflight} ->
      Process.demonitor(ref, [:flush])
      TaskLifecycle.terminate(inflight, state.task_supervisor)
    end)

    catalog = %{state.catalog | inflight: nil}
    selected = Map.new(state.selected, fn {key, entry} -> {key, %{entry | inflight: nil}} end)
    %{state | catalog: catalog, selected: selected, inflight_by_ref: %{}}
  end
end
