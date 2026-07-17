defmodule Aiur.Claude.Telemetry do
  @moduledoc """
  Owned, authenticated intake boundary for Claude Code OTLP log events.

  A loopback address is only a routing choice; every launch receives a fresh
  capability, and this registry proves the current run, repository-qualified
  ticket, attempt, and workspace generation before an event is trusted.
  """

  use GenServer

  alias Aiur.{Boot, Issue, TrackerIdentity}
  alias Aiur.Claude.Telemetry.{Event, Receiver}

  @source_version "claude-code-2.1.210"
  @emitter_version "2.1.210"
  @service_name "claude-code"
  @topic "claude_telemetry:events"
  @default_max_connections 12
  @default_max_inflight 3
  @default_max_events_per_window 120
  @default_rate_window_ms 60_000
  @default_replay_capacity 512

  @type launch :: %{
          required(:id) => reference(),
          required(:env) => [{String.t(), String.t() | false}],
          required(:source_version) => String.t()
        }

  @doc "Pinned Claude Code event contract accepted by this receiver."
  @spec source_version() :: String.t()
  def source_version, do: @source_version

  @doc "Subscribe to content-free authenticated Claude API-request events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)
  end

  @doc "Returns bounded receiver health without capabilities or payloads."
  @spec health(GenServer.server()) :: map()
  def health(server \\ __MODULE__), do: GenServer.call(server, :health)

  @doc """
  Establish a fresh producer generation before an owned Claude process starts.

  The returned environment is capability-bearing and must be passed straight to
  the child launch API. It must never be rendered, logged, persisted, or added
  to a command string.
  """
  @spec prepare_launch(Issue.t(), keyword()) :: {:ok, launch()} | {:error, atom()}
  def prepare_launch(issue, opts \\ [])

  def prepare_launch(%Issue{} = issue, opts) when is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    request = %{
      issue: issue,
      attempt_id: Keyword.get(opts, :attempt_id),
      worker_generation: worker_generation(Keyword.get(opts, :workspace_ownership)),
      backend: Keyword.get(opts, :backend),
      worker_host: Keyword.get(opts, :worker_host),
      owner: Keyword.get(opts, :owner, self())
    }

    GenServer.call(server, {:prepare_launch, request})
  catch
    :exit, _ -> {:error, :receiver_unavailable}
  end

  def prepare_launch(_issue, _opts), do: {:error, :invalid_correlation}

  @doc "Revoke a launch capability after teardown or a failed spawn."
  @spec revoke(launch() | map() | nil, GenServer.server()) :: :ok
  def revoke(launch, server \\ __MODULE__)

  def revoke(%{id: id}, server) when is_reference(id) do
    GenServer.call(server, {:revoke, id})
  catch
    :exit, _ -> :ok
  end

  def revoke(_launch, _server), do: :ok

  @doc false
  @spec authorize(String.t() | nil, GenServer.server()) :: {:ok, reference()} | {:error, atom()}
  def authorize(header, server \\ __MODULE__) do
    GenServer.call(server, {:authorize, header})
  catch
    :exit, _ -> {:error, :receiver_unavailable}
  end

  @doc false
  @spec release_request(reference(), GenServer.server()) :: :ok
  def release_request(request_id, server \\ __MODULE__)

  def release_request(request_id, server) when is_reference(request_id) do
    GenServer.cast(server, {:release_request, request_id})
  end

  def release_request(_request_id, _server), do: :ok

  @doc false
  @spec ingest(reference(), map(), GenServer.server()) :: :ok | {:error, atom()}
  def ingest(request_id, payload, server \\ __MODULE__)

  def ingest(request_id, payload, server) when is_reference(request_id) and is_map(payload) do
    GenServer.call(server, {:ingest, request_id, payload})
  catch
    :exit, _ -> {:error, :receiver_unavailable}
  end

  def ingest(_request_id, _payload, _server), do: {:error, :malformed}

  @doc false
  @spec reject(atom(), GenServer.server()) :: :ok
  def reject(reason, server \\ __MODULE__) when is_atom(reason) do
    GenServer.cast(server, {:reject, reason})
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      listener: nil,
      port: nil,
      max_inflight: Keyword.get(opts, :max_inflight, @default_max_inflight),
      max_events_per_window: Keyword.get(opts, :max_events_per_window, @default_max_events_per_window),
      rate_window_ms: Keyword.get(opts, :rate_window_ms, @default_rate_window_ms),
      replay_capacity: Keyword.get(opts, :replay_capacity, @default_replay_capacity),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      capability_fun: Keyword.get(opts, :capability_fun, &capability/0),
      capabilities: %{},
      launch_ids: %{},
      requests: %{},
      replay: %{set: MapSet.new(), queue: :queue.new()},
      rejections: %{},
      accepted: 0
    }

    case start_listener(opts) do
      {:ok, listener, port} -> {:ok, %{state | listener: listener, port: port}}
      {:error, reason} -> {:stop, {:telemetry_receiver_unavailable, reason}}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply,
     %{
       status: if(is_integer(state.port), do: :ready, else: :unavailable),
       source_versions: [@source_version],
       active_generations: map_size(state.capabilities),
       accepted: state.accepted,
       rejections: state.rejections
     }, state}
  end

  def handle_call({:prepare_launch, request}, _from, state) do
    with :ok <- validate_launch_request(request, state),
         {:ok, correlation} <- correlation(request),
         {:ok, capability} <- mint_capability(state) do
      launch_id = make_ref()
      now = now(state)

      {state, _replaced?} = revoke_matching_ticket(state, correlation.ticket)
      monitor = monitor_owner(request.owner)

      entry = %{
        launch_id: launch_id,
        correlation: correlation,
        source_contract: source_contract(),
        session_id: nil,
        owner_monitor: monitor,
        inflight: 0,
        rate_started_at: now,
        rate_count: 0
      }

      next = %{
        state
        | capabilities: Map.put(state.capabilities, capability, entry),
          launch_ids: Map.put(state.launch_ids, launch_id, capability)
      }

      {:reply, {:ok, %{id: launch_id, env: launch_env(state.port, capability), source_version: @source_version}}, next}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, count_rejection(state, reason)}
    end
  end

  def handle_call({:revoke, launch_id}, _from, state), do: {:reply, :ok, revoke_launch(state, launch_id)}

  def handle_call({:authorize, header}, _from, state) do
    with {:ok, capability} <- bearer_capability(header),
         {:ok, entry} <- Map.fetch(state.capabilities, capability),
         :ok <- available?(entry, state),
         {:ok, entry} <- take_rate_slots(entry, state, 1) do
      request_id = make_ref()

      next = %{
        state
        | capabilities: Map.put(state.capabilities, capability, %{entry | inflight: entry.inflight + 1}),
          requests: Map.put(state.requests, request_id, capability)
      }

      {:reply, {:ok, request_id}, next}
    else
      :error -> {:reply, {:error, :unknown_capability}, count_rejection(state, :unknown_capability)}
      {:error, reason} -> {:reply, {:error, reason}, count_rejection(state, reason)}
    end
  end

  def handle_call({:ingest, request_id, payload}, _from, state) do
    with {:ok, capability} <- Map.fetch(state.requests, request_id),
         {:ok, entry} <- Map.fetch(state.capabilities, capability),
         {:ok, events} <-
           Event.from_otlp(payload, entry.correlation, request_source_contract(entry.source_contract, capability)),
         :ok <- matching_session(entry, events),
         :ok <- unseen?(state.replay, events),
         {:ok, next_entry} <- take_rate_slots(entry, state, length(events) - 1) do
      events =
        Enum.map(events, fn event ->
          %{event | correlation: Map.put(event.correlation, :producer_generation, entry.correlation.producer_generation)}
        end)

      next_entry = %{next_entry | session_id: events |> hd() |> get_in([:correlation, :session_id])}

      next =
        state
        |> put_in([:capabilities, capability], next_entry)
        |> remember(events)
        |> Map.update!(:accepted, &(&1 + length(events)))

      Enum.each(events, &broadcast/1)
      {:reply, :ok, next}
    else
      :error -> {:reply, {:error, :unknown_request}, count_rejection(state, :unknown_request)}
      {:error, reason} -> {:reply, {:error, reason}, count_rejection(state, reason)}
    end
  end

  @impl true
  def handle_cast({:release_request, request_id}, state) do
    {:noreply, release_inflight_request(state, request_id)}
  end

  def handle_cast({:reject, reason}, state), do: {:noreply, count_rejection(state, reason)}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    launch_id =
      Enum.find_value(state.capabilities, fn {_, entry} ->
        if entry.owner_monitor == monitor, do: entry.launch_id
      end)

    {:noreply, if(is_reference(launch_id), do: revoke_launch(state, launch_id), else: state)}
  end

  def handle_info({:EXIT, listener, _reason}, %{listener: listener} = state) do
    {:stop, :telemetry_receiver_stopped, %{state | listener: nil, port: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{listener: listener}) when is_pid(listener) do
    # `Bandit.start_link/1` links the listener, but a normal GenServer stop
    # does not propagate an exit signal to linked processes. Tear it down
    # explicitly so a restarted receiver can reclaim the listener without
    # leaving a stale capability endpoint behind.
    monitor = Process.monitor(listener)
    Process.unlink(listener)
    Process.exit(listener, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, ^listener, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def format_status(status) when is_map(status) do
    Map.new(status, fn
      {:state, state} ->
        {:state,
         %{
           listener: state.listener,
           port: state.port,
           active_generations: map_size(state.capabilities),
           inflight_requests: map_size(state.requests),
           accepted: state.accepted,
           rejections: state.rejections
         }}

      {:message, _message} ->
        {:message, :redacted}

      entry ->
        entry
    end)
  end

  defp start_listener(opts) do
    receiver_opts = [registry: Keyword.get(opts, :name, __MODULE__)]

    with {:ok, listener} <-
           Bandit.start_link(
             plug: {Receiver, receiver_opts},
             scheme: :http,
             ip: {127, 0, 0, 1},
             port: Keyword.get(opts, :port, 0),
             startup_log: false,
             thousand_island_options: [
               num_acceptors: 1,
               num_connections: Keyword.get(opts, :max_connections, @default_max_connections)
             ]
           ),
         {:ok, {_ip, port}} <- ThousandIsland.listener_info(listener) do
      {:ok, listener, port}
    else
      :error -> {:error, :listener_info_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_launch_request(%{backend: backend, worker_host: nil, worker_generation: generation, issue: issue}, state)
       when backend in ["claude", "claude-repl"] and is_integer(generation) and generation > 0 and is_integer(state.port) do
    if TrackerIdentity.joinable?(Issue.tracker_identity(issue)), do: :ok, else: {:error, :missing_tracker_identity}
  end

  defp validate_launch_request(%{worker_host: worker_host}, _state) when is_binary(worker_host), do: {:error, :remote_worker_unsupported}
  defp validate_launch_request(_request, _state), do: {:error, :invalid_correlation}

  defp correlation(%{issue: issue, attempt_id: attempt_id, worker_generation: worker_generation, backend: backend})
       when is_binary(attempt_id) and backend in ["claude", "claude-repl"] do
    {:ok,
     %{
       run_id: Boot.run_id(),
       ticket: Issue.tracker_identity(issue),
       attempt_id: attempt_id,
       worker_generation: worker_generation,
       producer_generation: "producer-#{System.unique_integer([:positive, :monotonic])}",
       backend: backend
     }}
  end

  defp correlation(_request), do: {:error, :invalid_correlation}

  defp launch_env(port, capability) do
    endpoint = endpoint_from_port(port) <> "/v1/logs"

    [
      {"CLAUDE_CODE_ENABLE_TELEMETRY", "1"},
      {"OTEL_LOGS_EXPORTER", "otlp"},
      {"OTEL_METRICS_EXPORTER", "none"},
      {"OTEL_TRACES_EXPORTER", "none"},
      {"OTEL_EXPORTER_OTLP_PROTOCOL", "http/json"},
      {"OTEL_EXPORTER_OTLP_LOGS_PROTOCOL", "http/json"},
      {"OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", endpoint},
      {"OTEL_EXPORTER_OTLP_HEADERS", "Authorization=Bearer #{capability}"},
      {"OTEL_EXPORTER_OTLP_LOGS_HEADERS", "Authorization=Bearer #{capability}"},
      {"OTEL_LOG_USER_PROMPTS", "0"},
      {"OTEL_LOG_ASSISTANT_RESPONSES", "0"},
      {"OTEL_LOG_TOOL_DETAILS", "0"},
      {"OTEL_LOG_TOOL_CONTENT", "0"},
      {"OTEL_LOG_RAW_API_BODIES", "0"},
      {"OTEL_RESOURCE_ATTRIBUTES", false}
    ]
  end

  defp source_contract do
    %{
      emitter_version: @emitter_version,
      service_name: @service_name,
      source_version: @source_version
    }
  end

  defp request_source_contract(source_contract, capability) do
    Map.put(source_contract, :forbidden_values, [
      capability,
      "Bearer #{capability}",
      "Authorization=Bearer #{capability}"
    ])
  end

  defp bearer_capability("Bearer " <> capability) when byte_size(capability) == 43, do: {:ok, capability}
  defp bearer_capability(_header), do: {:error, :unauthenticated}

  defp available?(%{inflight: inflight}, %{max_inflight: max}) when inflight < max, do: :ok
  defp available?(_entry, _state), do: {:error, :concurrent_limit}

  defp take_rate_slots(entry, state, event_count) when is_integer(event_count) and event_count > 0 do
    current = now(state)
    elapsed = current - entry.rate_started_at
    entry = if elapsed >= state.rate_window_ms, do: %{entry | rate_started_at: current, rate_count: 0}, else: entry

    if entry.rate_count + event_count <= state.max_events_per_window do
      {:ok, %{entry | rate_count: entry.rate_count + event_count}}
    else
      {:error, :rate_limited}
    end
  end

  defp take_rate_slots(entry, _state, 0), do: {:ok, entry}

  defp matching_session(%{session_id: current}, events) when is_list(events) do
    session_ids = events |> Enum.map(&get_in(&1, [:correlation, :session_id])) |> Enum.uniq()

    cond do
      length(session_ids) != 1 -> {:error, :stale_session}
      is_nil(current) -> :ok
      session_ids == [current] -> :ok
      true -> {:error, :stale_session}
    end
  end

  defp unseen?(%{set: set}, events) when is_list(events) do
    keys = Enum.map(events, &Event.replay_key/1)

    if Enum.any?(keys, &MapSet.member?(set, &1)) or MapSet.size(MapSet.new(keys)) != length(keys), do: {:error, :replay}, else: :ok
  end

  defp remember(state, events) do
    {queue, set} =
      Enum.reduce(events, {state.replay.queue, state.replay.set}, fn event, {queue, set} ->
        key = Event.replay_key(event)
        {:queue.in(key, queue), MapSet.put(set, key)}
      end)

    {queue, set} = trim_replay(queue, set, state.replay_capacity)
    %{state | replay: %{queue: queue, set: set}}
  end

  defp trim_replay(queue, set, max) do
    if :queue.len(queue) > max do
      {{:value, dropped}, queue} = :queue.out(queue)
      trim_replay(queue, MapSet.delete(set, dropped), max)
    else
      {queue, set}
    end
  end

  defp release_inflight_request(state, request_id) do
    case Map.pop(state.requests, request_id) do
      {nil, _requests} ->
        state

      {capability, requests} ->
        capabilities =
          case Map.fetch(state.capabilities, capability) do
            {:ok, entry} ->
              Map.put(state.capabilities, capability, %{entry | inflight: max(entry.inflight - 1, 0)})

            :error ->
              state.capabilities
          end

        %{state | requests: requests, capabilities: capabilities}
    end
  end

  defp revoke_matching_ticket(state, ticket) do
    launch_ids =
      state.capabilities
      |> Enum.filter(fn {_, entry} -> entry.correlation.ticket == ticket end)
      |> Enum.map(fn {_, entry} -> entry.launch_id end)

    {Enum.reduce(launch_ids, state, fn launch_id, acc -> revoke_launch(acc, launch_id) end), launch_ids != []}
  end

  defp revoke_launch(state, launch_id) do
    case Map.pop(state.launch_ids, launch_id) do
      {nil, _launch_ids} ->
        state

      {capability, launch_ids} ->
        revoke_capability(state, capability, launch_ids)
    end
  end

  defp revoke_capability(state, capability, launch_ids) do
    case Map.pop(state.capabilities, capability) do
      {nil, _capabilities} ->
        %{state | launch_ids: launch_ids}

      {entry, capabilities} ->
        revoke_capability_entry(state, capability, launch_ids, entry, capabilities)
    end
  end

  defp revoke_capability_entry(state, capability, launch_ids, entry, capabilities) do
    demonitor_owner(entry.owner_monitor)

    %{
      state
      | capabilities: capabilities,
        launch_ids: launch_ids,
        requests: drop_capability_requests(state.requests, capability)
    }
  end

  defp demonitor_owner(monitor) when is_reference(monitor), do: Process.demonitor(monitor, [:flush])
  defp demonitor_owner(_monitor), do: :ok

  defp drop_capability_requests(requests, capability) do
    requests
    |> Enum.reject(fn {_request_id, request_capability} -> request_capability == capability end)
    |> Map.new()
  end

  defp count_rejection(state, reason) do
    reason =
      if reason in [
           :unauthenticated,
           :unknown_capability,
           :concurrent_limit,
           :rate_limited,
           :replay,
           :stale_session,
           :malformed,
           :oversize,
           :unsupported_event,
           :unsupported_version,
           :attribute_limit,
           :unknown_request,
           :capability_unavailable,
           :missing_tracker_identity,
           :remote_worker_unsupported,
           :invalid_correlation
         ], do: reason, else: :other

    %{state | rejections: Map.update(state.rejections, reason, 1, &(&1 + 1))}
  end

  defp broadcast(event) do
    if Process.whereis(Aiur.PubSub), do: Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:claude_telemetry, event})
    :ok
  end

  defp endpoint_from_port(port) when is_integer(port) and port > 0, do: "http://127.0.0.1:#{port}"
  defp endpoint_from_port(_port), do: nil

  defp mint_capability(%{capability_fun: fun, capabilities: capabilities}) when is_function(fun, 0) do
    case fun.() do
      capability when is_binary(capability) ->
        if valid_capability?(capability) and not is_map_key(capabilities, capability) do
          {:ok, capability}
        else
          {:error, :capability_unavailable}
        end

      _ ->
        {:error, :capability_unavailable}
    end
  end

  defp mint_capability(_state), do: {:error, :capability_unavailable}

  defp capability, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp valid_capability?(capability) do
    case Base.url_decode64(capability, padding: false) do
      {:ok, bytes} -> byte_size(bytes) == 32
      :error -> false
    end
  end

  defp now(%{clock: clock}), do: clock.()
  defp monitor_owner(owner) when is_pid(owner), do: Process.monitor(owner)
  defp monitor_owner(_owner), do: nil
  defp worker_generation(%{generation: generation}) when is_integer(generation), do: generation
  defp worker_generation(_ownership), do: nil
end
