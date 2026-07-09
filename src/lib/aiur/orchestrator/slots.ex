defmodule Aiur.Orchestrator.Slots do
  @moduledoc """
  Computes orchestrator worker-host and global dispatch slot capacity.
  """

  alias Aiur.{Config, Issue}
  alias Aiur.Orchestrator.{DispatchPolicy, State}

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

  @spec max_concurrent_agent_limit(State.t()) :: pos_integer()
  def max_concurrent_agent_limit(%State{} = state) do
    cond do
      is_integer(state.session_max_concurrent_agents) and state.session_max_concurrent_agents > 0 ->
        state.session_max_concurrent_agents

      is_integer(state.max_concurrent_agents) and state.max_concurrent_agents > 0 ->
        state.max_concurrent_agents

      true ->
        Config.settings!().agent.max_concurrent_agents
    end
  end

  @spec max_concurrent_agent_status(State.t()) :: map()
  def max_concurrent_agent_status(%State{} = state) do
    active = State.active_running_count(state.running)
    max = max_concurrent_agent_limit(state)

    %{
      active: active,
      paused: State.paused_running_count(state.running),
      configured: state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents,
      max: max,
      session_override?: is_integer(state.session_max_concurrent_agents),
      draining?: active > max
    }
  end

  # Paused agents keep their slot reserved: a deliberate pause should not
  # free capacity for the polling loop to auto-claim the next agent:todo
  # ticket. Resuming a paused agent reuses the held slot via
  # `resume_paused_issue/2`, which bypasses this check.
  @spec available_slots(State.t()) :: non_neg_integer()
  def available_slots(%State{} = state) do
    used = State.active_running_count(state.running) + State.paused_running_count(state.running)
    max(max_concurrent_agent_limit(state) - used, 0)
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
