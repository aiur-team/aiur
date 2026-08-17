defmodule Aiur.Orchestrator.SnapshotStore do
  @moduledoc """
  Lock-free dashboard read model for fleet snapshots.

  Snapshot projection is coalesced in this process. Readers use
  `:persistent_term` directly, so neither a busy Orchestrator mailbox nor a
  SnapshotStore restart can remove the last-known-good fleet view.
  """

  use GenServer
  require Logger

  alias Aiur.Orchestrator.{SnapshotPublisher, StatusReport}
  alias Aiur.PollCadence
  alias AiurWeb.ObservabilityPubSub

  @cache_key __MODULE__
  @global_pause_key {__MODULE__, :global_pause}
  @projection_delay_ms 50

  # Staleness is load-aware: the freshness window derives from the
  # Orchestrator's own recent publish cadence so a busy-but-publishing
  # Orchestrator keeps its fleet view `:current` instead of demoting a
  # near-current snapshot to last-known-good under sustained dispatch.
  @publish_gap_history 4
  @stale_window_margin 2

  # Floors, not thresholds. Both windows below are `@stale_window_margin`
  # effective poll intervals wide (`Aiur.PollCadence`); these floors only keep
  # behaviour identical at the tight cadences that predate #2064, where two
  # cycles is a handful of seconds. See `stale_window_ceiling_ms/0` and
  # `stale_age_ceiling_ms/0`.
  @stale_window_ceiling_floor_ms 60_000

  # Age decides staleness; a backlogged mailbox only corroborates it. An
  # Orchestrator that wedges *after* draining its mailbox publishes nothing and
  # carries no backlog, so a depth-gated rule would serve an arbitrarily old
  # fleet view as current — the exact "stale renders as current" failure this
  # read model exists to prevent. Past this ceiling the view is stale whatever
  # the mailbox says.
  #
  # The ceiling is `@stale_window_margin` *effective* poll intervals: an idle
  # Orchestrator only writes new snapshot input on a poll tick, so two missed
  # ticks is the earliest moment "we should have heard by now" is true. The
  # previous constant justified itself as "four times the 30s default poll
  # cadence" — no 30s cadence has ever existed in this repo, and the real
  # default is 120s, widening to 1200s under idle plus webhook backoff. Deriving
  # it removes both the wrong number and the need to re-tune on the next
  # cadence change.
  #
  # The floor keeps the pre-#2064 behaviour intact: at `interval_seconds: 5` two
  # cycles is 10s, so without it a 5s deployment would start flagging snapshots
  # stale twelve times sooner than it does today.
  @stale_age_ceiling_floor_ms 120_000

  # Two distinct degraded states must never collapse into one operator-facing
  # message. A retained snapshot that has aged out is `{:stale, snapshot,
  # metadata}` — it still carries a usable fleet view plus its age. Only a
  # producer that has never published under the active generation is
  # `:snapshot_unpublished`, which genuinely has nothing to show.
  @type result ::
          {:current, map(), map()}
          | {:stale, map(), map()}
          | :snapshot_unpublished
          | :orchestrator_unavailable

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts a new producer generation without replacing a retained snapshot.

  The generation token fences completion messages from a stopped orchestrator
  that shared this registered name.
  """
  @spec begin_generation(GenServer.server()) :: reference()
  def begin_generation(orchestrator) do
    generation = make_ref()
    :persistent_term.put(generation_key(orchestrator), generation)
    :persistent_term.erase(global_pause_key(orchestrator))
    # A restarted Orchestrator inherits the prior instance's generation token;
    # drop its leftover write-model entry so the periodic publisher never casts
    # the previous instance's fenced input under the new token.
    SnapshotPublisher.clear(orchestrator)
    generation
  end

  @doc false
  @spec discard(GenServer.server()) :: :ok
  def discard(orchestrator) do
    :persistent_term.erase(generation_key(orchestrator))
    :persistent_term.erase(global_pause_key(orchestrator))
    :persistent_term.erase({@cache_key, orchestrator})
    :persistent_term.erase({@cache_key, :last_timeout_log, orchestrator})
    SnapshotPublisher.clear(orchestrator)
    :ok
  end

  @doc """
  Publishes authoritative global-pause metadata independently of fleet
  projection.

  This overlays a retained fleet snapshot during a same-name Orchestrator
  restart without treating that retained fleet view as a fresh projection.
  """
  @spec publish_global_pause(GenServer.server(), reference() | nil, map()) :: :ok
  def publish_global_pause(orchestrator, generation, %{globally_paused: paused} = global_pause)
      when is_boolean(paused) do
    if generation == active_generation(orchestrator) do
      :persistent_term.put(
        global_pause_key(orchestrator),
        %{generation: generation, global_pause: global_pause}
      )

      :ok = ObservabilityPubSub.broadcast_update()
    end

    :ok
  end

  @doc """
  Stores an already-projected snapshot. This is chiefly useful to lightweight
  Orchestrator implementations that do not own an `Aiur.Orchestrator.State`.

  `publish/3` additionally retains the projected state the payload was built
  from, which is what lets `read/3` build the `status`/`watch` rows on the
  reader's own process. A snapshot published without it can still serve the
  dashboard; a control query reading it reports no rows rather than an empty
  fleet.
  """
  @spec publish(GenServer.server(), map()) :: :ok
  def publish(orchestrator, snapshot) when is_map(snapshot), do: publish(orchestrator, snapshot, nil)

  @spec publish(GenServer.server(), map(), Aiur.Orchestrator.State.t() | nil) :: :ok
  def publish(orchestrator, snapshot, source_state) when is_map(snapshot) do
    generation = active_generation(orchestrator)
    put_snapshot(orchestrator, generation, snapshot, source_state)
    cache_global_pause(orchestrator, generation, snapshot)
    :ok = ObservabilityPubSub.broadcast_update()
    :ok
  end

  @doc """
  Drops the retained snapshot for an orchestrator.

  The inverse of `publish/2`. The retained view deliberately survives an
  Orchestrator restart, so anything that publishes under a shared registered
  name (chiefly tests) has to be able to put the read model back the way it
  found it — otherwise a stale fleet view outlives its publisher and is read as
  the current one.
  """
  @spec forget(GenServer.server()) :: :ok
  def forget(orchestrator) do
    :persistent_term.erase({@cache_key, orchestrator})
    :persistent_term.erase(global_pause_key(orchestrator))
    SnapshotPublisher.clear(orchestrator)
    :ok
  end

  @doc """
  Coalesces a state change for projection outside the Orchestrator process.
  """
  @spec publish_state(GenServer.server(), reference() | nil, Aiur.Orchestrator.State.t()) :: :ok
  def publish_state(orchestrator, generation, snapshot_input) do
    GenServer.cast(__MODULE__, {:publish_state, orchestrator, generation, snapshot_input})
    :ok
  end

  @doc """
  Reads the last published snapshot without sending a message to the
  Orchestrator. A cache is retained across Orchestrator restarts; its metadata
  makes that degraded state explicit instead of blanking the dashboard.

  Staleness is load-aware: a snapshot remains `:current` while it falls within
  a window derived from the Orchestrator's own recent publish cadence, so a
  busy-but-publishing Orchestrator under sustained dispatch does not demote a
  near-current fleet view to last-known-good. It is also cadence-derived: both
  the window and the hard ceiling are two effective poll intervals wide
  (`Aiur.PollCadence`), so changing `polling.interval_seconds` needs no edit
  here. That window is bounded: beyond `stale_age_ceiling_ms/0` the snapshot is
  `:stale` with reason `:snapshot_stalled` regardless of mailbox depth, so an
  Orchestrator that wedged after draining its mailbox cannot serve an old fleet
  view as current.

  A retained-but-aged snapshot is always returned as `{:stale, snapshot,
  metadata}` so callers can render last-known-good data with its age.
  `:snapshot_unpublished` is reserved for a live Orchestrator that has not
  published under the active generation, which is the expected state for a
  short window after every restart.
  """
  @spec read(GenServer.server(), timeout()) :: result()
  def read(orchestrator, timeout), do: read(orchestrator, timeout, [])

  @doc """
  As `read/2`, but `fleet_rows?: true` also materialises the `status`/`watch`
  row shape under `:statuses`.

  Those rows cost a `dispatch-budgets.json` read and a `RepoBase` call, so they
  are built here — on the reader's process, when an operator actually asks — and
  not in the projection, which runs on every state change. They are built from
  the same cache entry that produced the freshness metadata beside them, so the
  rows and their stated age always describe one moment.
  """
  @spec read(GenServer.server(), timeout(), keyword()) :: result()
  def read(orchestrator, timeout, opts) do
    case cached_snapshot(orchestrator) do
      nil ->
        no_snapshot_result(orchestrator)

      %{snapshot: snapshot, observed_at: observed_at, observed_at_ms: observed_at_ms} = cached ->
        snapshot = orchestrator |> overlay_global_pause(snapshot) |> maybe_put_fleet_rows(cached, opts)
        metadata = metadata(orchestrator, cached, observed_at, observed_at_ms, timeout)

        case metadata.status do
          :stale ->
            maybe_log_timeout(orchestrator, metadata)
            {:stale, snapshot, metadata}

          :current ->
            {:current, snapshot, metadata}
        end
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}, task_ref: nil, monitor_ref: nil, timer_ref: nil}}

  @impl true
  def handle_cast({:publish_state, orchestrator, generation, snapshot_input}, store) do
    if generation == active_generation(orchestrator) do
      pending = Map.put(store.pending, orchestrator, {generation, snapshot_input})
      {:noreply, store |> Map.put(:pending, pending) |> schedule_projection()}
    else
      {:noreply, store}
    end
  end

  @impl true
  def handle_info(:project_pending, %{task_ref: nil} = store) do
    {:noreply, store |> Map.put(:timer_ref, nil) |> start_projection()}
  end

  @impl true
  def handle_info({:snapshot_built, ref, orchestrator, generation, {:ok, snapshot, source_state}}, %{task_ref: ref} = store) do
    if generation == active_generation(orchestrator) do
      put_snapshot(orchestrator, generation, snapshot, source_state)
      :ok = ObservabilityPubSub.broadcast_update()
    end

    {:noreply, store |> clear_task() |> schedule_projection()}
  end

  def handle_info({:snapshot_built, ref, _orchestrator, _generation, {:error, error}}, %{task_ref: ref} = store) do
    Logger.debug("Skipping incomplete dashboard snapshot: #{Exception.message(error)}")
    {:noreply, store |> clear_task() |> schedule_projection()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = store) do
    if reason != :normal, do: Logger.debug("Dashboard snapshot projection exited: #{inspect(reason)}")
    {:noreply, store |> clear_task() |> schedule_projection()}
  end

  def handle_info(_message, store), do: {:noreply, store}

  defp start_projection(%{task_ref: nil, pending: pending} = store) when map_size(pending) > 0 do
    [{orchestrator, {generation, snapshot_input}}] = Enum.take(pending, 1)
    pending = Map.delete(pending, orchestrator)
    store_pid = self()
    task_ref = make_ref()

    pid =
      spawn(fn ->
        result =
          try do
            # The projected state travels with its payload so a later control
            # query can build the `status`/`watch` rows from it without paying
            # for them on every projection.
            {:ok, StatusReport.snapshot_payload(snapshot_input), snapshot_input}
          rescue
            error -> {:error, error}
          end

        send(store_pid, {:snapshot_built, task_ref, orchestrator, generation, result})
      end)

    %{store | pending: pending, task_ref: task_ref, monitor_ref: Process.monitor(pid)}
  end

  defp start_projection(store), do: store

  defp clear_task(store), do: %{store | task_ref: nil, monitor_ref: nil}

  defp schedule_projection(%{task_ref: nil, timer_ref: nil, pending: pending} = store) when map_size(pending) > 0 do
    %{store | timer_ref: Process.send_after(self(), :project_pending, @projection_delay_ms)}
  end

  defp schedule_projection(store), do: store

  defp put_snapshot(orchestrator, generation, snapshot, source_state) do
    previous = cached_snapshot(orchestrator)
    observed_at_ms = System.monotonic_time(:millisecond)

    # Gap history is scoped to one producer generation: a restarted
    # Orchestrator (same registered name) must not inherit the prior instance's
    # publish cadence, or its load-aware staleness window would carry a
    # widened margin (and mask a genuine stall) for up to the ceiling.
    recent_gaps_ms =
      case {Map.get(previous || %{}, :generation), Map.get(previous || %{}, :observed_at_ms)} do
        {^generation, previous_ms} when is_integer(previous_ms) ->
          gap_ms = max(observed_at_ms - previous_ms, 0)

          (Map.get(previous || %{}, :recent_gaps_ms, []) ++ [gap_ms])
          |> Enum.take(-@publish_gap_history)

        _new_or_changed_generation ->
          []
      end

    :persistent_term.put(
      {@cache_key, orchestrator},
      %{
        generation: generation,
        snapshot: snapshot,
        source_state: source_state,
        observed_at: DateTime.utc_now(),
        observed_at_ms: observed_at_ms,
        recent_gaps_ms: recent_gaps_ms
      }
    )
  end

  defp maybe_put_fleet_rows(snapshot, cached, opts) do
    if Keyword.get(opts, :fleet_rows?, false) do
      case Map.get(cached, :source_state) do
        %Aiur.Orchestrator.State{} = state -> Map.put(snapshot, :statuses, StatusReport.agent_statuses(state))
        _no_state -> snapshot
      end
    else
      snapshot
    end
  end

  defp cached_snapshot(orchestrator), do: :persistent_term.get({@cache_key, orchestrator}, nil)

  defp cache_global_pause(orchestrator, generation, %{globally_paused: paused} = snapshot)
       when is_boolean(paused) do
    global_pause =
      snapshot
      |> Map.get(:global_pause, %{})
      |> Map.put(:globally_paused, paused)

    :persistent_term.put(global_pause_key(orchestrator), %{generation: generation, global_pause: global_pause})
  end

  defp cache_global_pause(_orchestrator, _generation, _snapshot), do: :ok

  defp overlay_global_pause(orchestrator, snapshot) do
    case :persistent_term.get(global_pause_key(orchestrator), nil) do
      %{generation: generation, global_pause: %{globally_paused: paused} = global_pause} ->
        if generation == active_generation(orchestrator) and is_boolean(paused) do
          snapshot
          |> Map.put(:globally_paused, paused)
          |> Map.put(:global_pause, global_pause)
        else
          snapshot
        end

      _ ->
        snapshot
    end
  end

  defp no_snapshot_result(orchestrator) do
    case live_pid(orchestrator) do
      nil ->
        :orchestrator_unavailable

      pid ->
        maybe_log_initial_timeout(orchestrator, mailbox_depth(pid))
        :snapshot_unpublished
    end
  end

  defp metadata(orchestrator, cached, observed_at, observed_at_ms, timeout) do
    age_ms = max(System.monotonic_time(:millisecond) - observed_at_ms, 0)
    pid = live_pid(orchestrator)
    mailbox_depth = mailbox_depth(pid)
    freshness_window_ms = effective_window(timeout, Map.get(cached, :recent_gaps_ms, []))

    reason =
      cond do
        is_nil(pid) -> :orchestrator_unavailable
        Map.get(cached, :generation) != active_generation(orchestrator) -> :orchestrator_unavailable
        stale_behind_backlog?(age_ms, timeout, freshness_window_ms, mailbox_depth) -> :snapshot_timeout
        stale_beyond_ceiling?(age_ms) -> :snapshot_stalled
        true -> nil
      end

    %{
      status: if(reason, do: :stale, else: :current),
      reason: reason,
      observed_at: DateTime.to_iso8601(observed_at),
      age_ms: age_ms,
      age_seconds: div(age_ms, 1_000),
      freshness_window_ms: freshness_window_ms,
      orchestrator_mailbox_depth: mailbox_depth
    }
  end

  # The backlog-corroborated path: older than the configured timeout, outside
  # the load-aware window, and the Orchestrator is visibly behind. Under
  # sustained dispatch the Orchestrator publishes on a slower cadence, so
  # `freshness_window_ms` grows to cover that cadence; an Orchestrator that has
  # gone quiet relative to its own recent cadence is still flagged stale. This
  # is one of two paths — `stale_beyond_ceiling?/1` covers the drained-mailbox
  # wedge that this one cannot see — so mailbox depth never gates staleness on
  # its own.
  defp stale_behind_backlog?(age_ms, timeout, freshness_window_ms, mailbox_depth) do
    is_integer(timeout) and timeout >= 0 and is_integer(age_ms) and age_ms >= timeout and
      is_integer(freshness_window_ms) and age_ms >= freshness_window_ms and
      is_integer(mailbox_depth) and mailbox_depth > 0
  end

  # The depth-independent floor: no snapshot older than the ceiling is ever
  # reported as current, however quiet the producer's mailbox is.
  defp stale_beyond_ceiling?(age_ms), do: is_integer(age_ms) and age_ms >= stale_age_ceiling_ms()

  @doc false
  @spec stale_age_ceiling_ms() :: pos_integer()
  def stale_age_ceiling_ms do
    case Application.get_env(:aiur, :snapshot_stale_age_ceiling_ms, nil) do
      ceiling_ms when is_integer(ceiling_ms) and ceiling_ms > 0 ->
        ceiling_ms

      _unset_or_invalid ->
        PollCadence.stale_after_ms(@stale_window_margin, floor_ms: @stale_age_ceiling_floor_ms)
    end
  end

  defp stale_window_ceiling_ms do
    PollCadence.stale_after_ms(@stale_window_margin, floor_ms: @stale_window_ceiling_floor_ms)
  end

  # The caller's tolerance is honoured exactly: `read/3` never widens a window
  # the caller asked to be narrow. Deriving the tolerance from the cadence is
  # the *caller's* job — see `AiurWeb.OperatorControlCenter.PayloadLoader` and
  # the other dashboard readers, which pass
  # `PollCadence.snapshot_tolerance_ms/1` rather than a fixed 15s. A reader that
  # genuinely wants zero tolerance (a correctness-critical read) must still be
  # able to ask for it.
  #
  # The observed-gap term widens on top of that, capped so one long pause cannot
  # widen the window indefinitely. The cap itself is cadence-derived, because a
  # fixed 60s cap clamped the adaptive window to half the 120s cadence and so
  # disabled the very mechanism meant to absorb a slower producer.
  defp effective_window(timeout, gaps) when is_list(gaps) do
    case median(gaps) do
      nil ->
        timeout

      median_ms when is_integer(median_ms) and median_ms > 0 ->
        capped = min(median_ms * @stale_window_margin, stale_window_ceiling_ms())
        max(timeout, capped)

      _ ->
        timeout
    end
  end

  defp effective_window(timeout, _gaps), do: timeout

  defp median([]), do: nil

  defp median(gaps) do
    sorted = Enum.sort(gaps)
    length = length(sorted)
    middle = div(length, 2)

    if rem(length, 2) == 0 do
      div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
    else
      Enum.at(sorted, middle)
    end
  end

  defp maybe_log_timeout(orchestrator, %{reason: reason} = metadata) when reason in [:snapshot_timeout, :snapshot_stalled] do
    warning_key = {@cache_key, :last_timeout_log, orchestrator}

    if :persistent_term.get(warning_key, nil) != metadata.observed_at do
      :persistent_term.put(warning_key, metadata.observed_at)

      Logger.warning(
        "Dashboard snapshot timed out; serving last-known-good snapshot " <>
          "(orchestrator_mailbox_depth=#{metadata.orchestrator_mailbox_depth}, age_ms=#{metadata.age_ms})"
      )
    end
  end

  defp maybe_log_timeout(_orchestrator, _metadata), do: :ok

  defp maybe_log_initial_timeout(orchestrator, mailbox_depth) do
    warning_key = {@cache_key, :last_timeout_log, orchestrator}

    if :persistent_term.get(warning_key, nil) != :before_first_snapshot do
      :persistent_term.put(warning_key, :before_first_snapshot)

      Logger.warning(
        "Dashboard snapshot timed out before the first snapshot was published " <>
          "(orchestrator_mailbox_depth=#{mailbox_depth})"
      )
    end
  end

  defp live_pid(orchestrator) do
    case GenServer.whereis(orchestrator) do
      pid when is_pid(pid) -> if(Process.alive?(pid), do: pid, else: nil)
      _ -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp mailbox_depth(pid) when is_pid(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, depth} -> depth
      _ -> :unknown
    end
  end

  defp mailbox_depth(_pid), do: :unknown

  defp generation_key(orchestrator), do: {@cache_key, :generation, orchestrator}
  defp global_pause_key(orchestrator), do: {@global_pause_key, orchestrator}
  defp active_generation(orchestrator), do: :persistent_term.get(generation_key(orchestrator), nil)
end
