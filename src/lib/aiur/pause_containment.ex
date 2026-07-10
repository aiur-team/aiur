defmodule Aiur.PauseContainment do
  @moduledoc false

  use GenServer

  require Logger

  alias Aiur.Alerts
  alias Aiur.Claude.RemoteControl

  @default_grace_ms 5_000
  @liveness_poll_ms 1_000

  @type handle :: %{identifier: String.t(), generation: pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec register(String.t(), pos_integer(), pos_integer()) :: {:ok, handle()} | :ignored
  def register(identifier, root_pid, process_group_id) do
    register(identifier, root_pid, process_group_id, [])
  end

  @spec register(String.t(), pos_integer(), pos_integer(), keyword()) :: {:ok, handle()} | :ignored
  def register(identifier, root_pid, process_group_id, opts)
      when is_binary(identifier) and is_integer(root_pid) and root_pid > 0 and
             is_integer(process_group_id) and process_group_id > 0 and is_list(opts) do
    register(__MODULE__, identifier, root_pid, process_group_id, opts)
  end

  def register(server, identifier, root_pid, process_group_id)
      when is_binary(identifier) and is_integer(root_pid) and root_pid > 0 and
             is_integer(process_group_id) and process_group_id > 0 do
    register(server, identifier, root_pid, process_group_id, [])
  end

  def register(_identifier, _root_pid, _process_group_id, _opts), do: :ignored

  @spec register(GenServer.server(), String.t(), pos_integer(), pos_integer(), keyword()) :: {:ok, handle()} | :ignored
  def register(server, identifier, root_pid, process_group_id, opts)
      when is_binary(identifier) and is_integer(root_pid) and root_pid > 0 and
             is_integer(process_group_id) and process_group_id > 0 do
    call(server, {:register, identifier, root_pid, process_group_id, Map.new(opts)})
  end

  def register(_server, _identifier, _root_pid, _process_group_id, _opts), do: :ignored

  @spec arm(String.t()) :: {:ok, handle()} | :not_registered
  def arm(identifier) when is_binary(identifier), do: arm(__MODULE__, identifier)

  @spec arm(GenServer.server(), String.t()) :: {:ok, handle()} | :not_registered
  def arm(server, identifier) when is_binary(identifier), do: call(server, {:arm, identifier})

  @doc false
  @spec arm_target(String.t()) :: {:ok, handle()} | :not_registered
  def arm_target(target) when is_binary(target), do: arm_target(__MODULE__, target)

  @doc false
  @spec arm_target(GenServer.server(), String.t()) :: {:ok, handle()} | :not_registered
  def arm_target(server, target) when is_binary(target), do: call(server, {:arm_target, target})

  @spec confirm(handle()) :: :ok
  def confirm(%{identifier: identifier, generation: generation}) when is_binary(identifier) and is_integer(generation) do
    confirm(__MODULE__, %{identifier: identifier, generation: generation})
  end

  def confirm(_handle), do: :ok

  @spec confirm(GenServer.server(), handle()) :: :ok
  def confirm(server, %{identifier: identifier, generation: generation}) when is_binary(identifier) and is_integer(generation) do
    call(server, {:confirm, identifier, generation})
  end

  def confirm(_server, _handle), do: :ok

  @doc false
  @spec release(handle() | term()) :: :ok
  def release(%{identifier: identifier, generation: generation}) when is_binary(identifier) and is_integer(generation) do
    release(__MODULE__, %{identifier: identifier, generation: generation})
  end

  def release(_handle), do: :ok

  @doc false
  @spec release(GenServer.server(), handle()) :: :ok
  def release(server, %{identifier: identifier, generation: generation}) when is_binary(identifier) and is_integer(generation) do
    call(server, {:release, identifier, generation})
  end

  def release(_server, _handle), do: :ok

  @spec paused?(handle() | term()) :: boolean()
  def paused?(%{identifier: identifier, generation: generation}) when is_binary(identifier) and is_integer(generation) do
    paused?(__MODULE__, %{identifier: identifier, generation: generation})
  end

  def paused?(_handle), do: false

  @spec paused?(GenServer.server(), handle()) :: boolean()
  def paused?(server, %{identifier: identifier, generation: generation}) when is_binary(identifier) and is_integer(generation) do
    call(server, {:paused?, identifier, generation}) == true
  end

  def paused?(_server, _handle), do: false

  @spec unregister(handle() | term()) :: :ok
  def unregister(%{identifier: identifier, generation: generation}) when is_binary(identifier) and is_integer(generation) do
    unregister(__MODULE__, %{identifier: identifier, generation: generation})
  end

  def unregister(_handle), do: :ok

  @spec unregister(GenServer.server(), handle()) :: :ok
  def unregister(server, %{identifier: identifier, generation: generation}) when is_binary(identifier) and is_integer(generation) do
    call(server, {:unregister, identifier, generation})
  end

  def unregister(_server, _handle), do: :ok

  defp call(server, message) do
    GenServer.call(server, message, 1_000)
  catch
    :exit, _ -> :ignored
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       grace_ms: positive_integer(Keyword.get(opts, :grace_ms), @default_grace_ms),
       liveness_poll_ms: positive_integer(Keyword.get(opts, :liveness_poll_ms), @liveness_poll_ms),
       reap_fun: Keyword.get(opts, :reap_fun, &RemoteControl.graceful_kill_process_group/1),
       pid_alive_fun: Keyword.get(opts, :pid_alive_fun, &RemoteControl.process_alive?/1),
       event_fun: Keyword.get(opts, :event_fun, &emit_event/2),
       notify_fun: Keyword.get(opts, :notify_fun, &notify_orchestrator/3)
     }}
  end

  @impl true
  def handle_call({:register, identifier, root_pid, process_group_id, opts}, _from, state) do
    # `setsid` must make the port child its own leader. Refusing a mismatched
    # group is the critical guard against signalling an inherited daemon group.
    if root_pid == process_group_id do
      generation = System.unique_integer([:positive, :monotonic])

      entry = %{
        generation: generation,
        root_pid: root_pid,
        process_group_id: process_group_id,
        workspace: opts[:workspace],
        mode: :active,
        deadline_ref: nil,
        liveness_ref: nil
      }

      {:reply, {:ok, %{identifier: identifier, generation: generation}}, put_in(state.entries[identifier], entry)}
    else
      {:reply, :ignored, state}
    end
  end

  def handle_call({:arm, identifier}, _from, state) do
    arm_entry(state, identifier, Map.get(state.entries, identifier))
  end

  def handle_call({:arm_target, target}, _from, state) do
    {identifier, entry} = find_target_entry(state.entries, target)
    arm_entry(state, identifier, entry)
  end

  def handle_call({:confirm, identifier, generation}, _from, state) do
    case Map.get(state.entries, identifier) do
      %{generation: ^generation, mode: :armed} = entry ->
        cancel_timer(entry.deadline_ref)
        liveness_ref = Process.send_after(self(), {:check_liveness, identifier, generation}, state.liveness_poll_ms)
        paused = %{entry | mode: :paused, deadline_ref: nil, liveness_ref: liveness_ref}
        {:reply, :ok, put_in(state.entries[identifier], paused)}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:release, identifier, generation}, _from, state) do
    case Map.get(state.entries, identifier) do
      %{generation: ^generation, mode: mode} = entry when mode in [:armed, :paused, :failed, :reaping] ->
        cancel_timers(entry)
        released = %{entry | mode: :active, deadline_ref: nil, liveness_ref: nil}
        {:reply, :ok, put_in(state.entries[identifier], released)}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:paused?, identifier, generation}, _from, state) do
    paused? = match?(%{generation: ^generation, mode: mode} when mode in [:armed, :paused, :failed, :reaping], Map.get(state.entries, identifier))
    {:reply, paused?, state}
  end

  def handle_call({:unregister, identifier, generation}, _from, state) do
    # Unregister only drops tracking. Normal session teardown already reaps the
    # descendant tree via `AppServerPort.stop_port/1`; forceful group reaping
    # stays exclusive to the fallback path so a clean shutdown never hard-kills a
    # still-draining app-server.
    case Map.get(state.entries, identifier) do
      %{generation: ^generation} = entry ->
        cancel_timers(entry)
        {:reply, :ok, %{state | entries: Map.delete(state.entries, identifier)}}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:fallback, identifier, generation}, state) do
    case Map.get(state.entries, identifier) do
      %{generation: ^generation, mode: :armed} = entry ->
        {:noreply, start_reap(state, identifier, entry)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:check_liveness, identifier, generation}, state) do
    case Map.get(state.entries, identifier) do
      %{generation: ^generation, mode: :paused} = entry ->
        if state.pid_alive_fun.(entry.root_pid) do
          ref = Process.send_after(self(), {:check_liveness, identifier, generation}, state.liveness_poll_ms)
          {:noreply, put_in(state.entries[identifier].liveness_ref, ref)}
        else
          {:noreply, start_reap(state, identifier, entry)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:reaped, identifier, generation, result}, state) do
    case Map.get(state.entries, identifier) do
      %{generation: ^generation, mode: :reaping} = entry ->
        {:noreply, finish_reap(state, identifier, entry, result)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Reaping can block for seconds on the TERM->KILL grace waits, so it runs off
  # the GenServer loop: one agent's slow reap must never delay arming or
  # confirming a sibling agent's pause (the concurrent-incident case this
  # feature exists for). The entry parks in `:reaping` — still latched — until
  # the worker reports its result back.
  defp start_reap(state, identifier, entry) do
    cancel_timers(entry)
    emit(state, :fallback_started, identifier, entry, "Cooperative pause did not contain the agent; reaping its recorded process group.")

    owner = self()
    reap_fun = state.reap_fun
    process_group_id = entry.process_group_id
    generation = entry.generation

    spawn(fn ->
      result =
        try do
          reap_fun.(process_group_id)
        rescue
          error -> {:error, {:reap_crashed, error}}
        end

      send(owner, {:reaped, identifier, generation, result})
    end)

    put_in(state.entries[identifier], %{entry | mode: :reaping, deadline_ref: nil, liveness_ref: nil})
  end

  defp finish_reap(state, identifier, entry, {:ok, outcome}) when outcome in [:reaped, :gone] do
    emit(state, :fallback_succeeded, identifier, entry, "Recorded agent process group contained.")
    state.notify_fun.(identifier, entry.generation, :contained)
    %{state | entries: Map.delete(state.entries, identifier)}
  end

  defp finish_reap(state, identifier, entry, {:error, reason}) do
    emit(state, :fallback_failed, identifier, entry, "Recorded agent process group could not be contained: #{inspect(reason)}")
    state.notify_fun.(identifier, entry.generation, {:failed, reason})
    put_in(state.entries[identifier], %{entry | mode: :failed, deadline_ref: nil, liveness_ref: nil})
  end

  defp finish_reap(state, identifier, entry, other) do
    emit(state, :fallback_failed, identifier, entry, "Recorded agent process group returned an invalid containment result: #{inspect(other)}")
    state.notify_fun.(identifier, entry.generation, {:failed, :invalid_result})
    put_in(state.entries[identifier], %{entry | mode: :failed, deadline_ref: nil, liveness_ref: nil})
  end

  defp emit(state, stage, identifier, entry, reason) do
    state.event_fun.(stage, %{
      identifier: identifier,
      workspace: entry.workspace,
      generation: entry.generation,
      process_group_id: entry.process_group_id,
      reason: reason
    })
  rescue
    error -> Logger.warning("pause_containment event_failed stage=#{stage} error=#{inspect(error)}")
  end

  defp emit_event(stage, %{identifier: identifier, workspace: workspace, reason: reason}) do
    Alerts.emit_system("ticket.#{identifier}.agent.pause.#{stage}",
      issue: identifier,
      workspace: workspace,
      reason: reason,
      needs_attention: stage == :fallback_failed,
      severity: if(stage == :fallback_failed, do: "warning", else: "info")
    )
  end

  defp notify_orchestrator(identifier, generation, result) do
    if Process.whereis(Aiur.Orchestrator) do
      send(Aiur.Orchestrator, {:pause_containment_result, identifier, generation, result})
    end

    :ok
  end

  defp handle(identifier, entry), do: %{identifier: identifier, generation: entry.generation}

  defp arm_entry(state, identifier, %{mode: mode} = entry) when mode in [:armed, :paused, :failed, :reaping] do
    {:reply, {:ok, handle(identifier, entry)}, state}
  end

  defp arm_entry(state, identifier, entry) when is_binary(identifier) and is_map(entry) do
    deadline_ref = Process.send_after(self(), {:fallback, identifier, entry.generation}, state.grace_ms)
    armed = %{entry | mode: :armed, deadline_ref: deadline_ref}
    emit(state, :cooperative, identifier, armed, "Cooperative pause requested; containment deadline armed.")
    {:reply, {:ok, handle(identifier, armed)}, put_in(state.entries[identifier], armed)}
  end

  defp arm_entry(state, _identifier, _entry), do: {:reply, :not_registered, state}

  defp find_target_entry(entries, target) do
    case Map.get(entries, target) do
      entry when is_map(entry) ->
        {target, entry}

      _ ->
        match_suffix_entry(entries, target)
    end
  end

  defp match_suffix_entry(entries, target) do
    # Fail closed when a bare issue-number target matches more than one
    # registered identifier (the same number across two repos): arming the
    # wrong entry would let the fallback reap a sibling agent's group.
    case Enum.filter(entries, fn {identifier, _entry} -> String.ends_with?(identifier, "##{target}") end) do
      [{identifier, entry}] -> {identifier, entry}
      _ -> {nil, nil}
    end
  end

  defp cancel_timers(entry) do
    cancel_timer(entry.deadline_ref)
    cancel_timer(entry.liveness_ref)
  end

  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_ref), do: :ok

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
