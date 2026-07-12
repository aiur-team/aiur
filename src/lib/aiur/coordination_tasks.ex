defmodule Aiur.CoordinationTasks do
  @moduledoc """
  Non-blocking admission boundary for best-effort coordination side effects.

  Callers cast work into this dedicated mailbox and return immediately. The
  server runs one operation at a time under `Aiur.TaskSupervisor`, preserving
  agent event ordering while keeping slow downstream work outside both the
  caller and this server's process. A bounded timeout prevents one operation
  from starving every coordination signal behind it indefinitely.
  """

  use GenServer

  require Logger

  @default_timeout_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue((-> term()), GenServer.server()) :: :pending
  def enqueue(operation, server \\ __MODULE__) when is_function(operation, 0) do
    GenServer.cast(server, {:enqueue, operation})
    :pending
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       current: nil,
       queue: :queue.new(),
       timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
     }}
  end

  @impl true
  def handle_cast({:enqueue, operation}, state) do
    {:noreply, dispatch_next(%{state | queue: :queue.in(operation, state.queue)})}
  end

  @impl true
  def handle_info({ref, _result}, %{current: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, dispatch_next(%{state | current: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current: %{ref: ref}} = state) do
    Logger.error("coordination task failed reason=#{inspect(reason)}")
    {:noreply, dispatch_next(%{state | current: nil})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:coordination_timeout, ref}, %{current: %{ref: ref, pid: pid}} = state) do
    Logger.error("coordination task timed out timeout_ms=#{state.timeout_ms}")
    _ = Task.Supervisor.terminate_child(Aiur.TaskSupervisor, pid)
    {:noreply, dispatch_next(%{state | current: nil})}
  end

  def handle_info({:coordination_timeout, _ref}, state), do: {:noreply, state}

  defp dispatch_next(%{current: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, operation}, queue} ->
        task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, operation)
        Process.send_after(self(), {:coordination_timeout, task.ref}, state.timeout_ms)
        %{state | current: task, queue: queue}

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch_next(state), do: state
end
