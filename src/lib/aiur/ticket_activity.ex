defmodule Aiur.TicketActivity do
  @moduledoc """
  Headless-safe projection of content-free ticket activity observations.

  The projection owns progress, active agent stage, and latest safe event
  evidence. Execution and waiting state remain the responsibility of
  `Aiur.Orchestrator.StatusReport`.
  """

  use GenServer

  alias Aiur.{CurrentRunMembership, ProgressRetention, TicketObservation, TrackerIdentity}
  alias Aiur.Events
  alias Aiur.TicketActivity.Projection

  @pubsub Aiur.PubSub
  @topic "ticket-activity:changed"
  @default_prune_interval_ms 30_000
  @progress_debounce_ms 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec snapshot(TrackerIdentity.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def snapshot(identity, opts \\ []) do
    case GenServer.call(Keyword.get(opts, :server, __MODULE__), {:snapshot, identity, now(opts)}) do
      :not_found -> {:error, :not_found}
      snapshot -> {:ok, snapshot}
    end
  end

  @spec snapshots(keyword()) :: map()
  def snapshots(opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:snapshots, now(opts)}, Keyword.get(opts, :timeout, 5_000))
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @spec topic() :: String.t()
  def topic, do: @topic

  @impl true
  def init(opts) do
    membership_snapshot_fun = Keyword.get(opts, :membership_snapshot_fun, &CurrentRunMembership.snapshot/0)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    retention_all_fun = Keyword.get(opts, :retention_all_fun, &ProgressRetention.all/0)
    retention_retain_fun = Keyword.get(opts, :retention_retain_fun, &ProgressRetention.retain/2)
    current_members = current_members(membership_snapshot_fun, %{})
    now = now_fun.()

    # Seed the projection from durable retained progress so a restart does not
    # re-enter `unknown` for tickets that already reported (#1963). Freshness
    # is recomputed from each reading's own `observed_at`, so a just-landed
    # reading renders fresh and an aged one renders stale — both with the real
    # percent.
    projection =
      opts
      |> Projection.new()
      |> Projection.refresh_keys(MapSet.new(Map.keys(current_members)), now)
      |> seed_from_retention(retention_all_fun, now)

    state = %{
      projection: projection,
      current_members: current_members,
      membership_snapshot_fun: membership_snapshot_fun,
      now_fun: now_fun,
      retention_retain_fun: retention_retain_fun,
      progress_publish_fun: Keyword.get(opts, :progress_publish_fun, &Events.publish/2),
      progress_debounce_ms: positive_opt(opts, :progress_debounce_ms, @progress_debounce_ms),
      progress_publication: %{},
      prune_interval_ms: positive_opt(opts, :prune_interval_ms, @default_prune_interval_ms)
    }

    _ = Keyword.get(opts, :exchange_subscribe_fun, fn -> Events.subscribe("ticket.*.#") end).()
    _ = Keyword.get(opts, :membership_subscribe_fun, &CurrentRunMembership.subscribe/0).()
    schedule_prune(state.prune_interval_ms)
    {:ok, state}
  end

  # `ProgressRetention.all/0` degrades to `%{}` when the store is not running
  # (pre-boot, tests), so a missing store is just an unseeded boot, never a
  # crash. Malformed retained entries (a bug or corruption in the store) are
  # skipped rather than allowed to crash the projection at boot.
  defp seed_from_retention(projection, all_fun, now) do
    case all_fun.() do
      retained when is_map(retained) ->
        entries =
          Enum.flat_map(retained, fn
            {_key, %{identity: identity, progress: progress}}
            when is_struct(identity, TrackerIdentity) and is_map(progress) ->
              [{identity, progress}]

            _malformed ->
              []
          end)

        if entries == [] do
          projection
        else
          Projection.seed_progress(projection, entries, now)
        end

      _ ->
        projection
    end
  end

  @impl true
  def handle_call({:snapshot, identity, now}, _from, state) do
    {:reply, Projection.snapshot(state.projection, identity, now), state}
  end

  def handle_call({:snapshots, now}, _from, state) do
    {:reply, Projection.snapshots(state.projection, now), state}
  end

  @impl true
  def handle_info({:event, %{ticket_observation: %TicketObservation{} = observation}}, state) do
    case Projection.apply(state.projection, observation) do
      {:accepted, projection} ->
        state = %{state | projection: projection}
        retain_progress(state, observation.tracker_identity)
        broadcast_changed(observation.tracker_identity, projection, state.now_fun.())
        state = publish_progress(state, observation.tracker_identity, projection)
        {:noreply, state}

      {:ignored, _reason, projection} ->
        {:noreply, %{state | projection: projection}}
    end
  end

  def handle_info({:current_run_membership_changed, %{event: event}}, state) do
    identity = identity_from(event)
    next_state = refresh_member(state, identity)
    broadcast_if_changed(identity, state, next_state)
    {:noreply, next_state}
  end

  def handle_info({:current_run_membership_health_changed, _payload}, state) do
    next_state = refresh_membership_snapshot(state)
    broadcast_if_changed(nil, state, next_state)
    {:noreply, next_state}
  end

  def handle_info(:prune, state) do
    projection = Projection.prune(state.projection, state.now_fun.())
    broadcast_if_changed(nil, state, %{state | projection: projection})
    schedule_prune(state.prune_interval_ms)
    {:noreply, %{state | projection: projection}}
  end

  def handle_info({:flush_progress, identifier}, state) do
    case Map.get(state.progress_publication, identifier) do
      %{payload: payload, pending: fingerprint} = row when is_map(payload) ->
        {:noreply, send_progress(state, identifier, payload, fingerprint, row)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp refresh_member(state, identity) do
    if key = TrackerIdentity.github_key(identity) do
      current_members = Map.put(state.current_members, key, identity)
      keys = MapSet.new(Map.keys(current_members))

      projection =
        Projection.refresh_keys(state.projection, keys, state.now_fun.())

      %{state | current_members: current_members, projection: projection}
    else
      state
    end
  end

  # Best-effort, fire-and-forget: every accepted observation that leaves the
  # entry with a progress reading is handed to the durable store, which is
  # latest-`order`-wins and idempotent, so redundant casts are no-ops and the
  # store never blocks this projection process.
  defp retain_progress(%{projection: projection, retention_retain_fun: retain_fun}, identity) do
    case Projection.ordered_progress(projection, identity) do
      nil ->
        :ok

      progress ->
        _ = retain_fun.(identity, progress)
        :ok
    end
  end

  defp publish_progress(state, identity, projection) do
    case Projection.publication_reading(projection, identity) do
      reading when is_map(reading) ->
        queue_progress(state, identity.identifier, progress_payload(reading))

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp progress_payload(%{progress: progress, stage: stage}) do
    phase = progress[:phase] || get_in(stage || %{}, [:value]) || :work
    phase = if phase in [:plan, :work, :review, :pr, :ci, :merge], do: phase, else: :work
    source = progress[:progress_source] || :phase

    %{
      percent: max(progress.percent, phase_base(phase)),
      step: progress[:step] || phase_step(phase),
      phase: Atom.to_string(phase),
      source: Atom.to_string(source),
      checklist: checklist_payload(progress),
      updated_at: DateTime.to_iso8601(progress.observed_at)
    }
  end

  defp checklist_payload(%{total: total, done: done}) when is_integer(total) and total > 0,
    do: %{done: done, total: total}

  defp checklist_payload(_progress), do: nil

  defp queue_progress(state, identifier, payload) do
    now = System.monotonic_time(:millisecond)
    row = Map.get(state.progress_publication, identifier, %{sent: nil, fingerprint: nil, pending: nil, payload: nil, timer: nil})
    fingerprint = {payload.percent, payload.step}

    cond do
      fingerprint == row.fingerprint ->
        cancel_pending(state, identifier, row)

      fingerprint == row.pending ->
        state

      is_nil(row.sent) or now - row.sent >= state.progress_debounce_ms ->
        send_progress(state, identifier, payload, fingerprint, row)

      true ->
        timer = row.timer || Process.send_after(self(), {:flush_progress, identifier}, state.progress_debounce_ms - (now - row.sent))
        put_in(state, [:progress_publication, identifier], %{row | pending: fingerprint, payload: payload, timer: timer})
    end
  end

  defp cancel_pending(state, identifier, %{timer: timer} = row) do
    if timer, do: Process.cancel_timer(timer)
    put_in(state, [:progress_publication, identifier], %{row | pending: nil, payload: nil, timer: nil})
  end

  defp send_progress(state, identifier, payload, fingerprint, row) do
    _ = state.progress_publish_fun.("ticket.#{identifier}.progress", payload)
    put_in(state, [:progress_publication, identifier], %{row | sent: System.monotonic_time(:millisecond), fingerprint: fingerprint, pending: nil, payload: nil, timer: nil})
  end

  defp phase_base(:plan), do: 0
  defp phase_base(:work), do: 15
  defp phase_base(:review), do: 70
  defp phase_base(:pr), do: 80
  defp phase_base(:ci), do: 85
  defp phase_base(:merge), do: 95

  defp phase_step(:plan), do: "Planning the work"
  defp phase_step(:review), do: "Reviewing the changes"
  defp phase_step(:pr), do: "Preparing the pull request"
  defp phase_step(:ci), do: "Waiting for CI"
  defp phase_step(:merge), do: "Waiting for merge"
  defp phase_step(_phase), do: "Working through the plan"

  defp refresh_membership_snapshot(state) do
    members = current_members(state.membership_snapshot_fun, state.current_members)
    projection = Projection.refresh_keys(state.projection, MapSet.new(Map.keys(members)), state.now_fun.())
    %{state | current_members: members, projection: projection}
  end

  defp current_members(fun, previous) do
    cached = Map.new(previous, fn {key, identity} -> {identity, key} end)

    case fun.() do
      %{members: members} when is_list(members) ->
        Enum.reduce(members, %{}, &index_member(&1, &2, cached))

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp index_member(member, acc, cached) do
    identity = member_identity(member)
    key = Map.get_lazy(cached, identity, fn -> TrackerIdentity.github_key(identity) end)
    if key, do: Map.put(acc, key, identity), else: acc
  end

  defp member_identity(%{identity: identity}), do: identity
  defp member_identity(identity), do: identity
  defp identity_from(%{identity: identity}), do: identity
  defp identity_from(_event), do: nil

  defp broadcast_if_changed(identity, previous, current) do
    if Projection.generation(current.projection) != Projection.generation(previous.projection) do
      broadcast_changed(identity, current.projection, current.now_fun.())
    end
  end

  defp broadcast_changed(identity, projection, now) do
    if is_pid(Process.whereis(@pubsub)) do
      snapshot =
        if is_struct(identity, TrackerIdentity),
          do: Projection.snapshot(projection, identity, now)

      payload = %{
        generation: Projection.generation(projection),
        identity: identity,
        snapshot: snapshot,
        retention: Projection.snapshots(projection, now).retention
      }

      Phoenix.PubSub.broadcast(
        @pubsub,
        @topic,
        {:ticket_activity_changed, payload}
      )
    end

    :ok
  end

  defp schedule_prune(interval), do: Process.send_after(self(), :prune, interval)
  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())

  defp positive_opt(opts, key, default),
    do: if(is_integer(opts[key]) and opts[key] > 0, do: opts[key], else: default)
end
