defmodule Aiur.BuildOrder.TicketDetailCache do
  @moduledoc """
  Supervised, bounded cache for configured-repository ticket detail.

  The cache is deliberately in-memory. After restart, a ticket remains
  unavailable until a newly requested, complete detail read succeeds.

  Every refresh has a bounded deadline scoped to its identity and generation.
  A timed-out task is terminated and cannot later replace the timeout result.
  """

  use GenServer

  alias Aiur.BuildOrder.TicketDetail
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot, State}

  @default_freshness_ms 30_000
  @default_refresh_timeout_ms 30_000
  @default_max_entries 32
  @max_freshness_ms 300_000
  @max_refresh_timeout_ms 30_000
  @max_entries 100

  @type entry :: %{
          identity: Aiur.TrackerIdentity.t(),
          detail: Snapshot.t() | nil,
          failure: Failure.t() | nil,
          generation: pos_integer() | :unknown,
          last_access_ms: integer(),
          last_success_ms: integer() | nil,
          last_attempt_at: DateTime.t() | nil,
          inflight: %{generation: pos_integer(), pid: pid(), ref: reference(), timeout_ref: reference()} | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec request(GenServer.server(), Aiur.TrackerIdentity.t()) :: {:ok, State.t()} | {:error, Failure.t()}
  def request(server \\ __MODULE__, identity), do: GenServer.call(server, {:request, identity})

  @spec current(GenServer.server(), Aiur.TrackerIdentity.t()) :: {:ok, State.t()} | {:error, Failure.t()}
  def current(server \\ __MODULE__, identity), do: GenServer.call(server, {:current, identity})

  @spec subscribe(GenServer.server(), Aiur.TrackerIdentity.t()) :: :ok | {:error, Failure.t() | term()}
  def subscribe(server \\ __MODULE__, identity) do
    with {:ok, topic} <- GenServer.call(server, {:subscription_topic, identity}),
         do: Phoenix.PubSub.subscribe(Aiur.PubSub, topic)
  end

  @spec topic(Aiur.TrackerIdentity.t()) :: String.t()
  def topic(identity) do
    key = cache_key(identity)
    "build_order:detail:" <> Base.url_encode64(:erlang.term_to_binary(key), padding: false)
  end

  @impl true
  def init(opts) do
    opts = runtime_options(opts)

    {:ok,
     %{
       entries: %{},
       inflight_by_ref: %{},
       next_generation: 1,
       configured_repo: Keyword.get(opts, :configured_repo),
       freshness_ms: bounded_positive_option(opts, :freshness_ms, @default_freshness_ms, @max_freshness_ms),
       refresh_timeout_ms: refresh_timeout_ms(opts),
       max_entries: bounded_positive_option(opts, :max_entries, @default_max_entries, @max_entries),
       max_description_bytes:
         bounded_positive_option(
           opts,
           :max_description_bytes,
           TicketDetail.default_max_description_bytes(),
           TicketDetail.default_max_description_bytes()
         ),
       reader: Keyword.get(opts, :reader),
       task_supervisor: Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor),
       now: Keyword.get(opts, :now, &DateTime.utc_now/0),
       clock_ms: Keyword.get(opts, :clock_ms, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call({:request, identity}, _from, state) do
    with {:ok, identity, _configured_repo} <- TicketDetail.fetchable_identity(identity, detail_opts(state)),
         {:ok, state} <- ensure_entry(state, identity),
         {entry, state} <- touch(state, identity) do
      if fresh?(entry, state) or entry.inflight do
        {:reply, {:ok, state_for(entry, state)}, state}
      else
        {entry, state} = start_refresh(entry, state)
        {:reply, {:ok, state_for(entry, state)}, state}
      end
    else
      {:error, %Failure{} = failure} -> {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:current, identity}, _from, state) do
    case TicketDetail.fetchable_identity(identity, detail_opts(state)) do
      {:ok, identity, _configured_repo} -> current_reply(state, identity)
      {:error, %Failure{} = failure} -> {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:subscription_topic, identity}, _from, state) do
    case TicketDetail.fetchable_identity(identity, detail_opts(state)) do
      {:ok, identity, _configured_repo} -> {:reply, {:ok, topic(identity)}, state}
      {:error, %Failure{} = failure} -> {:reply, {:error, failure}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_completion(ref, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    {:noreply, apply_completion(ref, {:error, %Failure{kind: :transport}}, state)}
  end

  def handle_info({:refresh_timeout, ref, generation}, state) when is_reference(ref) and is_integer(generation) do
    {:noreply, timeout_refresh(ref, generation, state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_entry(state, identity) do
    key = cache_key(identity)

    if Map.has_key?(state.entries, key) do
      {:ok, state}
    else
      with {:ok, state} <- make_room(state) do
        entry = %{
          identity: identity,
          detail: nil,
          failure: nil,
          generation: :unknown,
          last_access_ms: now_ms(state),
          last_success_ms: nil,
          last_attempt_at: nil,
          inflight: nil
        }

        {:ok, %{state | entries: Map.put(state.entries, key, entry)}}
      end
    end
  end

  defp make_room(state) when map_size(state.entries) < state.max_entries, do: {:ok, state}

  defp make_room(state) do
    state.entries
    |> Enum.reject(fn {_key, entry} -> entry.inflight end)
    |> Enum.min_by(fn {_key, entry} -> entry.last_access_ms end, fn -> nil end)
    |> case do
      {key, entry} ->
        broadcast_state(evicted_state(entry), state)
        {:ok, %{state | entries: Map.delete(state.entries, key)}}

      nil ->
        {:error, %Failure{kind: :capacity}}
    end
  end

  defp touch(state, identity) do
    key = cache_key(identity)
    entry = %{Map.fetch!(state.entries, key) | last_access_ms: now_ms(state)}
    {entry, %{state | entries: Map.put(state.entries, key, entry)}}
  end

  defp start_refresh(entry, state) do
    generation = state.next_generation
    now = now(state)

    case start_task(state, entry.identity) do
      {:ok, task} ->
        timeout_ref = Process.send_after(self(), {:refresh_timeout, task.ref, generation}, state.refresh_timeout_ms)

        entry = %{
          entry
          | generation: generation,
            last_attempt_at: now,
            inflight: %{generation: generation, pid: task.pid, ref: task.ref, timeout_ref: timeout_ref}
        }

        state =
          %{state | next_generation: generation + 1, entries: Map.put(state.entries, cache_key(entry.identity), entry)}
          |> put_in([:inflight_by_ref, task.ref], cache_key(entry.identity))

        {entry, state}

      :error ->
        entry = %{
          entry
          | generation: generation,
            last_attempt_at: now,
            failure: %Failure{kind: :transport},
            inflight: nil
        }

        state = %{
          state
          | next_generation: generation + 1,
            entries: Map.put(state.entries, cache_key(entry.identity), entry)
        }

        broadcast(entry, state)
        {entry, state}
    end
  end

  defp start_task(state, identity) do
    try do
      {:ok, Task.Supervisor.async_nolink(state.task_supervisor, fn -> read(state, identity) end)}
    catch
      :exit, _reason -> :error
      :error, _reason -> :error
    end
  end

  defp read(%{reader: reader}, identity) when is_function(reader, 1), do: reader.(identity)

  defp read(state, identity) do
    TicketDetail.fetch(identity, detail_opts(state) ++ [max_description_bytes: state.max_description_bytes, now: now(state)])
  end

  defp apply_completion(ref, result, state) do
    case Map.pop(state.inflight_by_ref, ref) do
      {nil, _inflight_by_ref} ->
        state

      {key, inflight_by_ref} ->
        state = %{state | inflight_by_ref: inflight_by_ref}
        apply_entry_completion(key, ref, result, state)
    end
  end

  defp apply_entry_completion(key, ref, result, state) do
    case Map.fetch(state.entries, key) do
      {:ok, %{inflight: %{ref: ^ref, generation: generation, timeout_ref: timeout_ref}} = entry} ->
        Process.cancel_timer(timeout_ref)
        entry = complete_entry(entry, result, state, generation)
        state = %{state | entries: Map.put(state.entries, key, entry)}
        broadcast(entry, state)
        state

      _ ->
        state
    end
  end

  defp timeout_refresh(ref, generation, state) do
    case Map.get(state.inflight_by_ref, ref) do
      nil ->
        state

      key ->
        case Map.get(state.entries, key) do
          %{inflight: %{ref: ^ref, generation: ^generation, pid: pid}} ->
            _ = Task.Supervisor.terminate_child(state.task_supervisor, pid)
            Process.demonitor(ref, [:flush])
            apply_completion(ref, {:error, %Failure{kind: :timeout}}, state)

          _ ->
            state
        end
    end
  end

  defp complete_entry(
         %{identity: identity} = entry,
         {:ok, %Snapshot{identity: identity} = detail},
         state,
         _generation
       ) do
    %{entry | detail: detail, failure: nil, last_success_ms: now_ms(state), inflight: nil}
  end

  defp complete_entry(entry, {:ok, %Snapshot{}}, _state, _generation) do
    %{entry | failure: %Failure{kind: :provider_identity_mismatch}, inflight: nil}
  end

  defp complete_entry(entry, {:error, %Failure{} = failure}, _state, _generation) do
    %{entry | failure: failure, inflight: nil}
  end

  defp complete_entry(entry, _unexpected, _state, _generation) do
    %{entry | failure: %Failure{kind: :transport}, inflight: nil}
  end

  defp fresh?(%{detail: %Snapshot{}, failure: nil, last_success_ms: last_success_ms}, state)
       when is_integer(last_success_ms) do
    now_ms(state) - last_success_ms < state.freshness_ms
  end

  defp fresh?(_entry, _state), do: false

  defp state_for(%{detail: detail, failure: failure} = entry, state) do
    %State{
      identity: entry.identity,
      generation: entry.generation,
      health: health(detail, failure, entry, state),
      detail: detail,
      failure: failure,
      last_success_at: detail && detail.observed_at,
      last_attempt_at: entry.last_attempt_at
    }
  end

  defp current_reply(state, identity) do
    case Map.fetch(state.entries, cache_key(identity)) do
      {:ok, entry} -> {:reply, {:ok, state_for(entry, state)}, state}
      :error -> {:reply, {:ok, unavailable_state(identity)}, state}
    end
  end

  defp unavailable_state(identity), do: %State{identity: identity, generation: :unknown, health: :unavailable}

  defp evicted_state(entry) do
    %State{
      identity: entry.identity,
      generation: entry.generation,
      health: :unavailable,
      failure: %Failure{kind: :evicted}
    }
  end

  defp health(nil, _failure, _entry, _state), do: :unavailable
  defp health(%Snapshot{}, failure, _entry, _state) when not is_nil(failure), do: :stale
  defp health(%Snapshot{}, _failure, entry, state) when is_map(state), do: if(fresh?(entry, state), do: :healthy, else: :stale)
  defp health(%Snapshot{}, _failure, _entry, _state), do: :healthy

  defp broadcast(entry, state) do
    broadcast_state(state_for(entry, state), state)
  end

  defp broadcast_state(snapshot, _state) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic(snapshot.identity), {:ticket_detail_updated, snapshot})
    end
  end

  defp cache_key(%Aiur.TrackerIdentity{kind: kind, owner: owner, repository: repository, provider_id: provider_id}),
    do: {kind, String.downcase(owner), String.downcase(repository), provider_id}

  defp detail_opts(state) do
    if is_tuple(state.configured_repo), do: [configured_repo: state.configured_repo], else: []
  end

  defp bounded_positive_option(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= maximum -> value
      _ -> default
    end
  end

  defp refresh_timeout_ms(opts) do
    bounded_positive_option(opts, :refresh_timeout_ms, @default_refresh_timeout_ms, @max_refresh_timeout_ms)
  end

  defp runtime_options(opts) do
    case Keyword.pop(opts, :runtime_config?, false) do
      {true, opts} -> Keyword.merge(Aiur.Config.build_order_ticket_detail_cache_options(), opts)
      {_runtime_config?, opts} -> opts
    end
  end

  defp now(state), do: state.now.()
  defp now_ms(state), do: state.clock_ms.()
end
