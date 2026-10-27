defmodule Aiur.GitHub.Listeners.CommandScan do
  @moduledoc "Owns the repo-wide PR command cursor and conditional validators."
  use GenServer

  alias Aiur.GitHub.Listeners.CommandScan.Scan

  defstruct cursor: %Scan{}, pending_poll: nil, poll_queue: :queue.new()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    stop_poll(state.pending_poll)
    if state.pending_poll, do: GenServer.reply(state.pending_poll.from, {:error, :command_scan_reset})
    for {from, _opts} <- :queue.to_list(state.poll_queue), do: GenServer.reply(from, {:error, :command_scan_reset})
    {:reply, :ok, %__MODULE__{}}
  end

  def handle_call({:poll, opts}, from, %{pending_poll: nil} = state), do: {:noreply, start_poll(state, from, opts)}

  def handle_call({:poll, opts}, from, state),
    do: {:noreply, %{state | poll_queue: :queue.in({from, opts}, state.poll_queue)}}

  @impl true
  def handle_info({ref, result}, %{pending_poll: %{task: %{ref: ref}} = poll} = state) do
    Process.demonitor(ref, [:flush])
    Process.demonitor(poll.caller_ref, [:flush])
    next = %{state | pending_poll: nil, cursor: result}
    GenServer.reply(poll.from, :ok)
    {:noreply, next_poll(next)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending_poll: %{task: %{ref: ref}} = poll} = state) do
    Process.demonitor(poll.caller_ref, [:flush])
    GenServer.reply(poll.from, {:error, {:tracker_task_exit, reason}})
    {:noreply, next_poll(%{state | pending_poll: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{pending_poll: %{caller_ref: ref} = poll} = state) do
    stop_poll(poll)
    {:noreply, next_poll(%{state | pending_poll: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_poll(state.pending_poll)

  # Keep cancellation beside cursor application so reset cannot accept a late worker result.
  defp start_poll(state, from, opts) do
    caller_ref = Process.monitor(elem(from, 0))
    task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> Scan.scan_pr_commands(state.cursor, opts) end)
    %{state | pending_poll: %{task: task, from: from, caller_ref: caller_ref, opts: opts}}
  end

  defp next_poll(state) do
    case :queue.out(state.poll_queue) do
      {{:value, {from, opts}}, rest} -> start_poll(%{state | poll_queue: rest}, from, opts)
      {:empty, _} -> state
    end
  end

  defp stop_poll(nil), do: :ok

  defp stop_poll(poll) do
    Process.demonitor(poll.caller_ref, [:flush])
    Task.shutdown(poll.task, :brutal_kill)
    :ok
  end
end
