defmodule Aiur.Workspace.Ownership do
  @moduledoc """
  Guardian-owned workspace leases for one issue workspace generation.

  The runner can die before its Codex process group does. Registering the
  runner directly used to make that death release the destructive workspace
  lease immediately; a retry could then replace the cwd underneath the live
  child. A small unlinked guardian now owns the Registry entry, reaps a
  recorded process group on abnormal owner death, and releases only after the
  group is gone.
  """

  alias Aiur.Claude.RemoteControl

  @registry Aiur.Workspace.Ownership.Registry
  @guardian_call_timeout 5_000
  @reap_retry_ms 1_000

  @type phase :: :provisioning | :active | :reaping
  @type lease :: %{
          ticket: String.t(),
          generation: pos_integer(),
          owner_id: String.t(),
          phase: phase(),
          guardian: pid()
        }
  @type registry :: pid() | atom()

  @spec claim(String.t(), registry()) :: {:ok, lease()} | {:error, {:workspace_owned, {:ok, lease()} | :none}}
  def claim(ticket, registry \\ @registry), do: claim(ticket, registry, [])

  @doc false
  @spec claim(String.t(), registry(), keyword()) :: {:ok, lease()} | {:error, {:workspace_owned, {:ok, lease()} | :none}}
  def claim(ticket, registry, opts) when is_binary(ticket) and is_list(opts) do
    generation = System.unique_integer([:positive, :monotonic])
    owner = self()

    guardian =
      spawn(fn ->
        guardian_start(owner, ticket, generation, registry, opts)
      end)

    receive do
      {:workspace_guardian_claimed, ^guardian, result} -> result
    after
      @guardian_call_timeout ->
        Process.exit(guardian, :kill)
        {:error, {:workspace_owned, current(ticket, registry)}}
    end
  end

  @spec activate(lease(), registry()) :: {:ok, lease()} | {:error, :workspace_ownership_lost}
  def activate(lease, registry \\ @registry)

  def activate(%{guardian: guardian, generation: generation}, _registry) when is_pid(guardian) do
    guardian_call(guardian, {:activate, generation})
  end

  def activate(_lease, _registry), do: {:error, :workspace_ownership_lost}

  @spec track_process_group(lease(), integer()) :: :ok
  def track_process_group(%{guardian: guardian, generation: generation}, process_group_id)
      when is_pid(guardian) and is_integer(process_group_id) and process_group_id > 0 do
    guardian_call(guardian, {:track_process_group, generation, process_group_id})
  end

  def track_process_group(_lease, _process_group_id), do: :ok

  @spec release(lease(), registry()) :: :ok
  def release(lease, registry \\ @registry)

  def release(%{guardian: guardian, generation: generation}, _registry) when is_pid(guardian) do
    guardian_call(guardian, {:release, generation})
  end

  def release(_lease, _registry), do: :ok

  @doc false
  @spec wait_for_release(String.t(), pid(), registry()) :: :waiting | :available
  def wait_for_release(ticket, recipient, registry \\ @registry)
      when is_binary(ticket) and is_pid(recipient) do
    case Registry.lookup(registry, ticket) do
      [{guardian, _lease}] when is_pid(guardian) ->
        wait_for_guardian_release(guardian, recipient, registry, ticket)

      [] ->
        :available
    end
  end

  @spec current(String.t(), registry()) :: {:ok, lease()} | :none
  def current(ticket, registry \\ @registry) when is_binary(ticket) do
    case Registry.lookup(registry, ticket) do
      [{_guardian, lease}] -> {:ok, lease}
      [] -> :none
    end
  end

  @spec active?(String.t(), registry()) :: boolean()
  def active?(ticket, registry \\ @registry) when is_binary(ticket) do
    match?({:ok, %{phase: :active}}, current(ticket, registry))
  end

  @doc false
  @spec protected?(String.t(), registry()) :: boolean()
  def protected?(ticket, registry \\ @registry) when is_binary(ticket) do
    match?({:ok, %{phase: phase}} when phase in [:active, :reaping], current(ticket, registry))
  end

  @spec telemetry_metadata(lease()) :: map()
  def telemetry_metadata(%{owner_id: owner_id, generation: generation, phase: phase}) do
    %{workspace_owner: owner_id, workspace_generation: generation, workspace_phase: phase}
  end

  defp guardian_start(owner, ticket, generation, registry, opts) do
    lease = %{
      ticket: ticket,
      generation: generation,
      owner_id: "workspace:#{generation}",
      phase: :provisioning,
      guardian: self()
    }

    case Registry.register(registry, ticket, lease) do
      {:ok, _value} ->
        send(owner, {:workspace_guardian_claimed, self(), {:ok, lease}})

        guardian_loop(%{
          owner_ref: Process.monitor(owner),
          registry: registry,
          lease: lease,
          process_group_id: nil,
          waiters: MapSet.new(),
          reap_fun: Keyword.get(opts, :reap_fun, &RemoteControl.graceful_kill_process_group/1),
          group_alive_fun: Keyword.get(opts, :group_alive_fun, &RemoteControl.process_group_alive?/1),
          reaping?: false
        })

      {:error, {:already_registered, _pid}} ->
        send(owner, {:workspace_guardian_claimed, self(), {:error, {:workspace_owned, current(ticket, registry)}}})
    end
  end

  defp guardian_loop(state) do
    receive do
      {:workspace_guardian_call, from, ref, {:activate, generation}} ->
        {result, state} = activate_guardian(state, generation)
        send(from, {:workspace_guardian_reply, ref, result})
        guardian_loop(state)

      {:workspace_guardian_call, from, ref, {:track_process_group, generation, process_group_id}} ->
        result = if generation == state.lease.generation, do: :ok, else: :ok
        state = if generation == state.lease.generation, do: %{state | process_group_id: process_group_id}, else: state
        send(from, {:workspace_guardian_reply, ref, result})
        guardian_loop(state)

      {:workspace_guardian_call, from, ref, {:release, generation}} ->
        send(from, {:workspace_guardian_reply, ref, :ok})

        if generation == state.lease.generation do
          maybe_release_or_reap(state)
        else
          guardian_loop(state)
        end

      {:workspace_guardian_call, from, ref, {:wait_for_release, recipient}} when is_pid(recipient) ->
        send(from, {:workspace_guardian_reply, ref, :waiting})
        guardian_loop(%{state | waiters: MapSet.put(state.waiters, recipient)})

      {:DOWN, owner_ref, :process, _owner, _reason} when owner_ref == state.owner_ref ->
        maybe_release_or_reap(state)

      {:workspace_guardian_reaped, process_group_id} when process_group_id == state.process_group_id ->
        continue_after_reap(state)

      :workspace_guardian_retry_reap ->
        maybe_release_or_reap(%{state | reaping?: false})

      _other ->
        guardian_loop(state)
    end
  end

  defp activate_guardian(state, generation) when generation == state.lease.generation do
    case Registry.update_value(state.registry, state.lease.ticket, &Map.put(&1, :phase, :active)) do
      {%{generation: ^generation} = lease, _previous} -> {{:ok, lease}, %{state | lease: lease}}
      _ -> {{:error, :workspace_ownership_lost}, state}
    end
  end

  defp activate_guardian(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp maybe_release_or_reap(%{process_group_id: nil} = state), do: release_guardian(state)

  defp maybe_release_or_reap(%{reaping?: true} = state), do: guardian_loop(state)

  defp maybe_release_or_reap(%{process_group_id: process_group_id} = state) do
    if state.group_alive_fun.(process_group_id) do
      state = update_phase(state, :reaping)
      guardian = self()
      reap_fun = state.reap_fun

      spawn(fn ->
        _ = safe_reap(reap_fun, process_group_id)
        send(guardian, {:workspace_guardian_reaped, process_group_id})
      end)

      guardian_loop(%{state | reaping?: true})
    else
      release_guardian(state)
    end
  end

  defp continue_after_reap(state) do
    if state.group_alive_fun.(state.process_group_id) do
      Process.send_after(self(), :workspace_guardian_retry_reap, @reap_retry_ms)
      guardian_loop(%{state | reaping?: true})
    else
      release_guardian(state)
    end
  end

  defp release_guardian(state) do
    Registry.unregister(state.registry, state.lease.ticket)
    Enum.each(state.waiters, &send(&1, {:workspace_ownership_available, state.lease.ticket}))
    :ok
  end

  defp update_phase(state, phase) do
    case Registry.update_value(state.registry, state.lease.ticket, &Map.put(&1, :phase, phase)) do
      {%{} = lease, _previous} -> %{state | lease: lease}
      _ -> state
    end
  end

  defp safe_reap(reap_fun, process_group_id) do
    reap_fun.(process_group_id)
  rescue
    _ -> {:error, :reap_failed}
  end

  defp guardian_call(guardian, message) do
    ref = make_ref()
    send(guardian, {:workspace_guardian_call, self(), ref, message})

    receive do
      {:workspace_guardian_reply, ^ref, result} -> result
    after
      @guardian_call_timeout -> guardian_call_timeout_result(message)
    end
  end

  defp wait_for_guardian_release(guardian, recipient, registry, ticket) do
    ref = make_ref()
    send(guardian, {:workspace_guardian_call, self(), ref, {:wait_for_release, recipient}})

    receive do
      {:workspace_guardian_reply, ^ref, :waiting} -> :waiting
    after
      100 -> if(Registry.lookup(registry, ticket) == [], do: :available, else: :waiting)
    end
  end

  defp guardian_call_timeout_result({:activate, _generation}), do: {:error, :workspace_ownership_lost}
  defp guardian_call_timeout_result(_message), do: :ok
end
