defmodule Aiur.CoordinationTasks do
  @moduledoc """
  Bounded, keyed admission for best-effort coordination side effects.

  Operations for one key retain admission order while independent keys may run
  concurrently. Admission is synchronous and bounded so callers never report
  acceptance unless this process owns the work.
  """

  use GenServer

  require Logger

  @default_admission_timeout_ms 100
  @default_operation_timeout_ms 30_000
  @default_max_pending 1_000
  @default_max_concurrency 16

  @type key :: term()
  @type admission_result ::
          :pending
          | {:error, :coordination_overloaded | :coordination_unavailable | :coordination_indeterminate}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue(key(), (-> term()), GenServer.server(), keyword(), timeout()) :: admission_result()
  def enqueue(
        key,
        operation,
        server \\ __MODULE__,
        opts \\ [],
        admission_timeout \\ @default_admission_timeout_ms
      )
      when is_function(operation, 0) do
    operation_timeout = Keyword.get(opts, :operation_timeout, :default)
    deadline = admission_deadline(admission_timeout)

    GenServer.call(
      server,
      {:enqueue, key, operation, operation_timeout, deadline},
      admission_timeout
    )
  catch
    :exit, {:timeout, _reason} -> {:error, :coordination_indeterminate}
    :exit, _reason -> {:error, :coordination_unavailable}
  end

  @doc """
  Runs an operation through the same keyed lane and returns its terminal result.

  This is for mutations whose caller-visible result is part of the tool contract.
  The default infinite call timeout leaves operation-specific timeouts to the
  downstream service instead of releasing the key while a mutation may still land.
  """
  @spec run(key(), (-> term()), GenServer.server(), keyword(), timeout()) :: term()
  def run(
        key,
        operation,
        server \\ __MODULE__,
        opts \\ [],
        call_timeout \\ :infinity
      )
      when is_function(operation, 0) do
    operation_timeout = Keyword.get(opts, :operation_timeout, :default)
    GenServer.call(server, {:run, key, operation, operation_timeout}, call_timeout)
  catch
    :exit, {:timeout, _reason} -> {:error, :coordination_indeterminate}
    :exit, _reason -> {:error, :coordination_unavailable}
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       active: %{},
       queues: %{},
       pending: 0,
       operation_timeout_ms: Keyword.get(opts, :operation_timeout_ms, @default_operation_timeout_ms),
       max_pending: Keyword.get(opts, :max_pending, @default_max_pending),
       max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency)
     }}
  end

  @impl true
  def handle_call(
        {:enqueue, _key, _operation, _timeout, _deadline},
        _from,
        %{pending: pending, max_pending: max} = state
      )
      when pending >= max do
    {:reply, {:error, :coordination_overloaded}, state}
  end

  def handle_call({:enqueue, key, operation, timeout, deadline}, _from, state) do
    if admission_expired?(deadline) do
      {:reply, {:error, :coordination_unavailable}, state}
    else
      entry = entry(operation, timeout, nil, state)
      {:reply, :pending, enqueue_entry(key, entry, state)}
    end
  end

  def handle_call({:run, _key, _operation, _timeout}, _from, %{pending: pending, max_pending: max} = state)
      when pending >= max do
    {:reply, {:error, :coordination_overloaded}, state}
  end

  def handle_call({:run, key, operation, timeout}, from, state) do
    entry = entry(operation, timeout, from, state)
    {:noreply, enqueue_entry(key, entry, state)}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    if match?({:error, _reason}, result) do
      Logger.error("coordination operation failed reason=#{inspect(result)}")
    end

    finish(ref, result, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if reason != :normal, do: Logger.error("coordination task failed reason=#{inspect(reason)}")
    finish(ref, {:error, {:coordination_task_exit, reason}}, state)
  end

  def handle_info({:coordination_timeout, ref}, state) do
    case active_by_ref(state.active, ref) do
      {key, task} ->
        Logger.error("coordination task timed out timeout_ms=#{state.operation_timeout_ms}")
        Process.unlink(task.pid)
        _ = Task.Supervisor.terminate_child(Aiur.TaskSupervisor, task.pid)
        complete(key, task, {:error, :coordination_timeout}, state)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(ref, result, state) do
    case active_by_ref(state.active, ref) do
      {key, task} -> complete(key, task, result, state)
      nil -> {:noreply, state}
    end
  end

  defp complete(key, task, result, state) do
    Process.demonitor(task.ref, [:flush])
    cancel_timer(task.timer, task.ref)
    reply(task.reply_to, result)
    {:noreply, dispatch(%{state | active: Map.delete(state.active, key)})}
  end

  defp reply(nil, _result), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)

  defp cancel_timer(nil, _ref), do: :ok

  defp cancel_timer(timer, ref) do
    case Process.cancel_timer(timer) do
      false ->
        receive do
          {:coordination_timeout, ^ref} -> :ok
        after
          0 -> :ok
        end

      _remaining ->
        :ok
    end
  end

  defp dispatch(state) when map_size(state.active) >= state.max_concurrency, do: state

  defp dispatch(state) do
    case Enum.find(state.queues, fn {key, queue} ->
           not Map.has_key?(state.active, key) and not :queue.is_empty(queue)
         end) do
      {key, queue} ->
        {{:value, entry}, queue} = :queue.out(queue)

        task = Task.Supervisor.async(Aiur.TaskSupervisor, fn -> safely_run(entry.operation) end)

        task =
          task
          |> Map.put(:timer, schedule_timeout(task.ref, entry.timeout))
          |> Map.put(:reply_to, entry.reply_to)

        queues = if :queue.is_empty(queue), do: Map.delete(state.queues, key), else: Map.put(state.queues, key, queue)

        state
        |> Map.put(:queues, queues)
        |> Map.put(:pending, state.pending - 1)
        |> Map.put(:active, Map.put(state.active, key, task))
        |> dispatch()

      nil ->
        state
    end
  end

  defp active_by_ref(active, ref) do
    Enum.find(active, fn {_key, task} -> task.ref == ref end)
  end

  defp enqueue_entry(key, entry, state) do
    queue = Map.get(state.queues, key, :queue.new())
    dispatch(%{state | queues: Map.put(state.queues, key, :queue.in(entry, queue)), pending: state.pending + 1})
  end

  defp entry(operation, timeout, reply_to, state) do
    %{
      operation: operation,
      timeout: resolve_timeout(timeout, state.operation_timeout_ms),
      reply_to: reply_to
    }
  end

  defp safely_run(operation) do
    operation.()
  rescue
    error -> {:error, {:coordination_operation_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:coordination_operation_failure, kind, reason}}
  end

  defp admission_deadline(:infinity), do: :infinity

  defp admission_deadline(timeout) when is_integer(timeout) and timeout >= 0 do
    System.monotonic_time(:millisecond) + timeout
  end

  defp admission_expired?(:infinity), do: false
  defp admission_expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp resolve_timeout(:default, default), do: default
  defp resolve_timeout(:infinity, _default), do: :infinity
  defp resolve_timeout(timeout, _default) when is_integer(timeout) and timeout > 0, do: timeout

  defp schedule_timeout(_ref, :infinity), do: nil
  defp schedule_timeout(ref, timeout), do: Process.send_after(self(), {:coordination_timeout, ref}, timeout)
end
