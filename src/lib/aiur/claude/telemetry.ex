defmodule Aiur.Claude.Telemetry do
  @moduledoc """
  Owned, authenticated intake boundary for Claude Code OTLP log events.

  A loopback address is only a routing choice; every launch receives a fresh
  capability, and this registry proves the current run, repository-qualified
  ticket, attempt, and workspace generation before an event is trusted.
  """

  use GenServer

  import Aiur.Claude.Telemetry.LaunchRegistry

  alias Aiur.Issue
  alias Aiur.Claude.Telemetry.{Contract, Ingest, Receiver}

  @topic "claude_telemetry:events"
  @usage_topic "claude_telemetry:usage"
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
  def source_version, do: Contract.source_version()

  @doc "Subscribe to content-free authenticated Claude API-request events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)
  end

  @doc "Subscribe to attributed usage envelopes and bounded coverage facts."
  @spec subscribe_usage() :: :ok | {:error, term()}
  def subscribe_usage do
    Phoenix.PubSub.subscribe(Aiur.PubSub, @usage_topic)
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
      owner: Keyword.get(opts, :owner, self()),
      execution_recipient: Keyword.get(opts, :execution_recipient)
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
       source_versions: [Contract.source_version()],
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
        issue_id: Map.get(request.issue, :id),
        execution_recipient: request.execution_recipient,
        resolved_model: nil,
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

      {:reply, {:ok, %{id: launch_id, env: launch_env(state.port, capability), source_version: Contract.source_version()}}, next}
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
         {:ok, entry} <- Map.fetch(state.capabilities, capability) do
      Ingest.ingest_authenticated(state, capability, entry, payload)
    else
      :error -> {:reply, {:error, :unknown_request}, count_rejection(state, :unknown_request)}
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
end
