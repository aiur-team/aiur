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
  @type admission_result :: :pending | {:error, :coordination_overloaded | :coordination_unavailable}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue(key(), (-> term()), GenServer.server(), timeout()) :: admission_result()
  def enqueue(key, operation, server \\ __MODULE__, timeout \\ @default_admission_timeout_ms)
      when is_function(operation, 0) do
    GenServer.call(server, {:enqueue, key, operation}, timeout)
  catch
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
  def handle_call({:enqueue, _key, _operation}, _from, %{pending: pending, max_pending: max} = state)
      when pending >= max do
    {:reply, {:error, :coordination_overloaded}, state}
  end

  def handle_call({:enqueue, key, operation}, _from, state) do
    queue = Map.get(state.queues, key, :queue.new())
    state = %{state | queues: Map.put(state.queues, key, :queue.in(operation, queue)), pending: state.pending + 1}
    {:reply, :pending, dispatch(state)}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref), do: finish(ref, state)

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if reason != :normal, do: Logger.error("coordination task failed reason=#{inspect(reason)}")
    finish(ref, state)
  end

  def handle_info({:coordination_timeout, ref}, state) do
    case active_by_ref(state.active, ref) do
      {key, task} ->
        Logger.error("coordination task timed out timeout_ms=#{state.operation_timeout_ms}")
        _ = Task.Supervisor.terminate_child(Aiur.TaskSupervisor, task.pid)
        complete(key, task, state)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(ref, state) do
    case active_by_ref(state.active, ref) do
      {key, task} -> complete(key, task, state)
      nil -> {:noreply, state}
    end
  end

  defp complete(key, task, state) do
    Process.demonitor(task.ref, [:flush])
    cancel_timer(task.timer, task.ref)
    {:noreply, dispatch(%{state | active: Map.delete(state.active, key)})}
  end

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
        {{:value, operation}, queue} = :queue.out(queue)
        task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, operation)
        timer = Process.send_after(self(), {:coordination_timeout, task.ref}, state.operation_timeout_ms)
        queues = if :queue.is_empty(queue), do: Map.delete(state.queues, key), else: Map.put(state.queues, key, queue)

        state
        |> Map.put(:queues, queues)
        |> Map.put(:pending, state.pending - 1)
        |> Map.put(:active, Map.put(state.active, key, Map.put(task, :timer, timer)))
        |> dispatch()

      nil ->
        state
    end
  end

  defp active_by_ref(active, ref) do
    Enum.find(active, fn {_key, task} -> task.ref == ref end)
  end
end
