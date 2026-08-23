defmodule Aiur.Orchestrator.Slots do
  @moduledoc """
  Computes orchestrator worker-host and global dispatch slot capacity.
  """

  alias Aiur.{Config, Issue}
  alias Aiur.Orchestrator.{DispatchPolicy, State, StatusReport}

  @spec max_concurrent_agents() :: map() | :unavailable
  def max_concurrent_agents, do: max_concurrent_agents(Aiur.Orchestrator)

  @spec max_concurrent_agents(GenServer.server()) :: map() | :unavailable
  def max_concurrent_agents(server) do
    if GenServer.whereis(server) do
      GenServer.call(server, :max_concurrent_agents, 5_000)
    else
      :unavailable
    end
  catch
    :exit, _ -> :unavailable
  end

  @spec adjust_max_concurrent_agents(integer()) :: {:ok, map()} | {:error, term()}
  def adjust_max_concurrent_agents(delta),
    do: adjust_max_concurrent_agents(Aiur.Orchestrator, delta)

  @spec adjust_max_concurrent_agents(GenServer.server(), integer()) ::
          {:ok, map()} | {:error, term()}
  def adjust_max_concurrent_agents(server, delta) when is_integer(delta),
    do: control_api_call(server, {:adjust_max_concurrent_agents, delta})

  @spec set_max_concurrent_agents(pos_integer()) :: {:ok, map()} | {:error, term()}
  def set_max_concurrent_agents(next),
    do: set_max_concurrent_agents(Aiur.Orchestrator, next)

  @spec set_max_concurrent_agents(GenServer.server(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def set_max_concurrent_agents(server, next) when is_integer(next) and next > 0,
    do: control_api_call(server, {:set_max_concurrent_agents, next})

  @spec max_concurrent_agents_call(State.t()) :: {:reply, map(), State.t()}
  def max_concurrent_agents_call(%State{} = state) do
    {:reply, max_concurrent_agent_status(state), state}
  end

  @spec adjust_max_concurrent_agents_call(State.t(), integer()) ::
          {:reply, {:ok, map()}, State.t()}
  def adjust_max_concurrent_agents_call(%State{} = state, delta) when is_integer(delta) do
    next = max(max_concurrent_agent_limit(state) + delta, 1)
    apply_session_max_concurrent_agents(state, next)
  end

  @spec set_max_concurrent_agents_call(State.t(), pos_integer()) ::
          {:reply, {:ok, map()}, State.t()}
  def set_max_concurrent_agents_call(%State{} = state, next)
      when is_integer(next) and next > 0 do
    apply_session_max_concurrent_agents(state, next)
  end

  @spec apply_session_max_concurrent_agents(State.t(), pos_integer()) ::
          {:reply, {:ok, map()}, State.t()}
  def apply_session_max_concurrent_agents(%State{session_max_concurrent_agents: next} = state, next) when is_integer(next) do
    {:reply, {:ok, max_concurrent_agent_status(state)}, state}
  end

  def apply_session_max_concurrent_agents(%State{} = state, next) when is_integer(next) do
    # The cap applies to state immediately. Do NOT force an immediate full poll
    # from here: `Lifecycle.request_refresh_state/1` used to schedule a 0ms tick
    # that runs the whole poll cycle — firehose, CI and candidate-fetch GitHub
    # requests, each bounded to the 10s orchestrator request deadline — inline in
    # this process. That wedged the orchestrator mailbox for ~10s after every
    # `set max-agents`, so the write (and any control call that landed meanwhile)
    # contended with the busy state and could either time out at the 5s
    # `GenServer.call` budget (the first-write-after-restart failure, since the
    # initial poll is equally slow) or race the launcher's 10s control-RPC
    # watchdog (#2137). Re-dispatch still happens on the normal poll cadence; the
    # cap and its status read take effect immediately.
    state = Map.put(state, :session_max_concurrent_agents, next)

    StatusReport.notify_dashboard(state)
    {:reply, {:ok, max_concurrent_agent_status(state)}, state}
  end

  defp control_api_call(server, request) do
    if GenServer.whereis(server) do
      GenServer.call(server, request, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @spec slot_status(State.t()) :: %{active: non_neg_integer(), paused: non_neg_integer()}
  def slot_status(%State{} = state) do
    %{
      active: State.active_running_count(state.running),
      paused: State.paused_running_count(state.running)
    }
  end

  @spec select_worker_host(State.t(), String.t() | nil) :: String.t() | :no_worker_capacity | nil
  def select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  @spec preferred_worker_host_available?(term(), term()) :: boolean()
  def preferred_worker_host_available?(preferred_worker_host, hosts)
      when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  def preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  @spec least_loaded_worker_host(State.t(), [String.t()]) :: String.t()
  def least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  @spec running_worker_host_count(term(), term()) :: non_neg_integer()
  def running_worker_host_count(running, worker_host)
      when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host} = entry} -> State.active_running_entry?(entry)
      _ -> false
    end)
  end

  @spec worker_slots_available?(State.t()) :: boolean()
  def worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  @spec worker_slots_available?(State.t(), String.t() | nil) :: boolean()
  def worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  @spec worker_host_slots_available?(State.t(), String.t()) :: boolean()
  def worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  # `--max-agents N` at launch lands in `:max_concurrent_agents_override`
  # (set by `Aiur.CLI`). Returns a positive integer or nil (no override).
  @spec launch_max_concurrent_agents_override() :: pos_integer() | nil
  def launch_max_concurrent_agents_override do
    case Application.get_env(:aiur, :max_concurrent_agents_override) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  # `--pause` at launch lands in `:launch_globally_paused` (set by `Aiur.CLI`).
  # When true, the orchestrator cold-starts globally paused and never provisions
  # agents until the operator unpauses. Distinct from per-agent pause state.
  @spec launch_globally_paused?() :: boolean()
  def launch_globally_paused? do
    Application.get_env(:aiur, :launch_globally_paused, false) == true
  end

  @spec max_concurrent_agent_limit(State.t()) :: pos_integer()
  def max_concurrent_agent_limit(%State{} = state) do
    cond do
      is_integer(state.session_max_concurrent_agents) and state.session_max_concurrent_agents > 0 ->
        state.session_max_concurrent_agents

      is_integer(state.max_concurrent_agents) and state.max_concurrent_agents > 0 ->
        state.max_concurrent_agents

      true ->
        Config.max_concurrent_agents()
    end
  end

  @spec effective_concurrent_agent_limit(State.t()) :: pos_integer()
  def effective_concurrent_agent_limit(%State{} = state) do
    static_limit = max_concurrent_agent_limit(state)

    case state.effective_concurrent_agents do
      effective when is_integer(effective) and effective > 0 -> min(effective, static_limit)
      _ -> static_limit
    end
  end

  @spec max_concurrent_agent_status(State.t()) :: map()
  def max_concurrent_agent_status(%State{} = state) do
    active = State.active_running_count(state.running)
    reserved_paused = State.reserved_paused_running_count(state.running)
    max = max_concurrent_agent_limit(state)
    sample = state.dispatch_capacity_sample

    %{
      active: active,
      paused: State.paused_running_count(state.running),
      reserved_paused: reserved_paused,
      occupied: active + reserved_paused,
      configured: state.max_concurrent_agents || Config.max_concurrent_agents(),
      max: max,
      effective: effective_concurrent_agent_limit(state),
      available: available_slots(state),
      capacity_hold: state.capacity_hold,
      load: Map.get(sample, :load, :unavailable),
      load_threshold: Map.get(sample, :load_threshold),
      schedulers: Map.get(sample, :schedulers),
      queued_demand?: queued_dispatch_demand?(state),
      session_override?: is_integer(state.session_max_concurrent_agents),
      draining?: active > max
    }
  end

  defp queued_dispatch_demand?(%State{candidate_snapshot_fresh?: false}), do: false

  defp queued_dispatch_demand?(%State{} = state) do
    DispatchPolicy.queued_dispatch_demand?(Map.values(state.last_polled_issues), state)
  end

  # Deliberate/Executor pauses keep their slot reserved so the polling loop
  # cannot auto-claim replacement work. CI-wait, dependency-blocked, and
  # duration-capped pauses are the exception: the daemon owns those waits (or
  # the agent has simply hit its time cap and is parked for review), so the
  # parked runner releases normal dispatch capacity (#2329).
  @spec used_slots(State.t()) :: non_neg_integer()
  def used_slots(%State{} = state) do
    State.active_running_count(state.running) +
      State.reserved_paused_running_count(state.running)
  end

  @spec available_slots(State.t()) :: non_neg_integer()
  def available_slots(%State{globally_paused: true}), do: 0

  def available_slots(%State{} = state) do
    max(effective_concurrent_agent_limit(state) - used_slots(state), 0)
  end

  @spec resume_worker_slot_available?(State.t(), term()) :: boolean()
  def resume_worker_slot_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    worker_host_slots_available?(state, worker_host)
  end

  def resume_worker_slot_available?(%State{}, _worker_host), do: true

  @spec dispatch_slots_available?(Issue.t(), State.t()) :: boolean()
  def dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and DispatchPolicy.state_slots_available?(issue, state)
  end
end
