defmodule Aiur.TicketActivity do
  @moduledoc """
  Headless-safe projection of content-free ticket activity observations.

  The projection owns progress, active agent stage, and latest safe event
  evidence. Execution and waiting state remain the responsibility of
  `Aiur.Orchestrator.StatusReport`.
  """

  use GenServer

  alias Aiur.{CurrentRunMembership, ProgressRetention, TicketObservation, TrackerIdentity}
  alias Aiur.Events.Exchange
  alias Aiur.TicketActivity.Projection

  @pubsub Aiur.PubSub
  @topic "ticket-activity:changed"
  @default_prune_interval_ms 30_000

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
    current_members = current_members(membership_snapshot_fun)
    now = now_fun.()

    # Seed the projection from durable retained progress so a restart does not
    # re-enter `unknown` for tickets that already reported (#1963). Freshness
    # is recomputed from each reading's own `observed_at`, so a just-landed
    # reading renders fresh and an aged one renders stale — both with the real
    # percent.
    projection =
      opts
      |> Projection.new()
      |> Projection.refresh_members(current_members, now)
      |> seed_from_retention(retention_all_fun, now)

    state = %{
      projection: projection,
      current_members: Map.new(current_members, &{TrackerIdentity.github_key(&1), &1}),
      membership_snapshot_fun: membership_snapshot_fun,
      now_fun: now_fun,
      retention_retain_fun: retention_retain_fun,
      prune_interval_ms: positive_opt(opts, :prune_interval_ms, @default_prune_interval_ms)
    }

    _ = Keyword.get(opts, :exchange_subscribe_fun, fn -> Exchange.subscribe("ticket.*.#") end).()
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

  def handle_info(_message, state), do: {:noreply, state}

  defp refresh_member(state, identity) do
    if TrackerIdentity.joinable?(identity) do
      current_members = Map.put(state.current_members, TrackerIdentity.github_key(identity), identity)
      identities = Map.values(current_members)

      projection =
        Projection.refresh_members(state.projection, identities, state.now_fun.())

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

  defp refresh_membership_snapshot(state) do
    members = current_members(state.membership_snapshot_fun)
    identities = Map.new(members, &{TrackerIdentity.github_key(&1), &1})
    projection = Projection.refresh_members(state.projection, members, state.now_fun.())
    %{state | current_members: identities, projection: projection}
  end

  defp current_members(fun) do
    case fun.() do
      %{members: members} when is_list(members) ->
        members
        |> Enum.map(&member_identity/1)
        |> Enum.filter(&TrackerIdentity.joinable?/1)

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
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
