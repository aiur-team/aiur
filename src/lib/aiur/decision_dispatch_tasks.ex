defmodule Aiur.DecisionDispatchTasks do
  @moduledoc """
  Bounded, keyed execution for Decision delivery dispatches.

  Jobs for one ticket retain admission order while independent tickets can use
  the global worker capacity fairly. Every admitted job produces one terminal
  callback carrying the caller's opaque correlation value.
  """

  use GenServer

  alias __MODULE__.{Owner, Queue, Saturation, Worker}

  @default_operation_timeout_ms 30_000
  @default_max_pending 100
  @default_max_concurrency 8

  @type ticket :: term()
  @type correlation :: term()
  @type terminal_result :: term()
  @type callback :: (correlation(), terminal_result() -> term())
  @type admission_result ::
          :pending | {:error, :decision_dispatch_overloaded | :decision_dispatch_unavailable}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Admits one dispatch job and returns only after admission is definitive.

  The infinite local call timeout prevents a caller from observing an
  indeterminate timeout after this coordinator has accepted the job.
  """
  @spec enqueue(ticket(), correlation(), (-> term()), callback(), GenServer.server(), keyword()) ::
          admission_result()
  def enqueue(ticket, correlation, operation, callback, server \\ __MODULE__, opts \\ [])
      when is_function(operation, 0) and is_function(callback, 2) do
    operation_timeout = Keyword.get(opts, :operation_timeout, :default)
    owner = Keyword.get(opts, :owner, self())
    GenServer.call(server, {:enqueue, ticket, correlation, operation, callback, operation_timeout, owner}, :infinity)
  catch
    :exit, _reason -> {:error, :decision_dispatch_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    max_pending = Keyword.get(opts, :max_pending, @default_max_pending)

    {:ok,
     %{
       active: %{},
       owner_monitors: %{},
       queues: %{},
       runnable_tickets: :queue.new(),
       runnable_ticket_set: MapSet.new(),
       pending: 0,
       max_pending: max_pending,
       max_pending_per_ticket: Keyword.get(opts, :max_pending_per_ticket, default_per_ticket_limit(max_pending)),
       max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
       operation_timeout_ms: Keyword.get(opts, :operation_timeout_ms, @default_operation_timeout_ms),
       task_starter: Keyword.get(opts, :task_starter, &Worker.start_supervised/1),
       saturation_notifier: Keyword.get(opts, :saturation_notifier, &Saturation.notify/1),
       saturated?: false
     }}
  end

  @impl true
  def handle_call({:enqueue, ticket, correlation, operation, callback, timeout, owner}, _from, state) do
    if Queue.admit?(state, ticket) do
      entry = %{
        callback: callback,
        correlation: correlation,
        operation: operation,
        owner: owner,
        timeout: resolve_timeout(timeout, state.operation_timeout_ms)
      }

      state = state |> Owner.monitor(owner) |> Queue.put(ticket, entry)
      {:reply, :pending, state, {:continue, :dispatch}}
    else
      {:reply, {:error, :decision_dispatch_overloaded}, Saturation.mark(state)}
    end
  end

  @impl true
  def handle_continue(:dispatch, state), do: {:noreply, dispatch(state)}

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case active_by_ref(state.active, ref) do
      {ticket, task} -> complete(ticket, task, result, state)
      nil -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case active_by_ref(state.active, ref) do
      {ticket, task} ->
        complete(ticket, task, {:error, {:decision_dispatch_task_exit, reason}}, state)

      nil ->
        case Owner.by_ref(state.owner_monitors, ref) do
          nil -> {:noreply, state}
          owner -> {:noreply, state |> Owner.purge(owner) |> dispatch()}
        end
    end
  end

  def handle_info({:decision_dispatch_timeout, ref}, state) do
    case active_by_ref(state.active, ref) do
      {ticket, task} ->
        state = deactivate(ticket, task, state)
        _ = Worker.terminate(task)
        Worker.notify(task, {:error, :decision_dispatch_timeout})
        {:noreply, state |> Queue.make_runnable(ticket) |> Owner.cleanup(task.owner) |> dispatch()}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch(state) when map_size(state.active) >= state.max_concurrency,
    do: Saturation.maybe_resolve(state)

  defp dispatch(state) do
    case Queue.pop(state) do
      {ticket, entry, state} ->
        case Worker.start(state.task_starter, entry.operation) do
          {:ok, task} ->
            state
            |> activate(ticket, entry, task)
            |> Saturation.maybe_resolve()
            |> dispatch()

          {:error, reason} ->
            Worker.notify(entry, {:error, {:decision_dispatch_task_start_failed, reason}})

            state
            |> Queue.make_runnable(ticket)
            |> Owner.cleanup(entry.owner)
            |> Saturation.maybe_resolve()
            |> dispatch()
        end

      :empty ->
        Saturation.maybe_resolve(state)
    end
  end

  defp complete(ticket, task, result, state) do
    state = deactivate(ticket, task, state)
    Worker.notify(task, result)
    {:noreply, state |> Queue.make_runnable(ticket) |> Owner.cleanup(task.owner) |> dispatch()}
  end

  defp deactivate(ticket, task, state) do
    Process.demonitor(task.ref, [:flush])
    Worker.cancel_timeout(task.timer, task.ref)
    %{state | active: Map.delete(state.active, ticket)}
  end

  defp activate(state, ticket, entry, task) do
    active_task = %{
      callback: entry.callback,
      correlation: entry.correlation,
      owner: entry.owner,
      pid: task.pid,
      ref: task.ref,
      timer: Worker.schedule_timeout(task.ref, entry.timeout)
    }

    %{state | active: Map.put(state.active, ticket, active_task)}
  end

  defp active_by_ref(active, ref) do
    Enum.find(active, fn {_ticket, task} -> task.ref == ref end)
  end

  defp resolve_timeout(:default, default), do: default
  defp resolve_timeout(:infinity, _default), do: :infinity
  defp resolve_timeout(timeout, _default) when is_integer(timeout) and timeout > 0, do: timeout

  defp default_per_ticket_limit(max_pending) when max_pending > 1, do: max_pending - 1
  defp default_per_ticket_limit(_max_pending), do: 1
end
