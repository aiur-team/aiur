defmodule Aiur.AgentList.AppMocks do
  @moduledoc false

  defmodule MockPaneManager do
    @moduledoc false

    use GenServer

    def start_link(_parent), do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, %{opens: MapSet.new(), open_waiters: %{}, parked: MapSet.new()}}

    def await_open(pid, identifier, command),
      do: GenServer.call(pid, {:await_open, identifier, command}, :infinity)

    def park_open(pid, identifier), do: GenServer.call(pid, {:park_open, identifier})

    def open_conversation(pid, identifier, command, opts \\ []) do
      GenServer.call(pid, {:open, identifier, command, opts})
    end

    def handle_call({:open, identifier, command, _opts}, _from, state) do
      event = {identifier, command}

      state =
        state.open_waiters
        |> Map.get(event, [])
        |> Enum.reduce(state, fn waiter, state ->
          GenServer.reply(waiter, :ok)
          state
        end)
        |> Map.update!(:opens, &MapSet.put(&1, event))
        |> Map.update!(:open_waiters, &Map.delete(&1, event))

      if MapSet.member?(state.parked, identifier),
        do: {:noreply, state},
        else: {:reply, {:ok, "%999"}, state}
    end

    def handle_call({:await_open, identifier, command}, from, state) do
      event = {identifier, command}

      if MapSet.member?(state.opens, event) do
        {:reply, :ok, state}
      else
        {:noreply, update_in(state.open_waiters[event], fn waiters -> [from | waiters || []] end)}
      end
    end

    def handle_call({:park_open, identifier}, _from, state),
      do: {:reply, :ok, update_in(state.parked, &MapSet.put(&1, identifier))}

    def handle_call({:attach, _identifier, _command, _opts}, _from, state) do
      {:reply, {:error, :no_focused_pane}, state}
    end

    def handle_call(:list, _from, state), do: {:reply, %{}, state}

    def handle_call(:toggle_orientation, _from, state),
      do: {:reply, {:ok, :vertical}, state}
  end

  defmodule MockOrchestrator do
    @moduledoc false

    use GenServer

    def start_link(_parent), do: GenServer.start_link(__MODULE__, :ok)

    def init(:ok),
      do:
        {:ok,
         %{
           max: 2,
           resume_result: {:ok, :resumed},
           adjust_result: nil,
           rc_result: {:ok, :on},
           calls: MapSet.new(),
           call_waiters: %{}
         }}

    def await_call(pid, call), do: GenServer.call(pid, {:await_call, call}, :infinity)
    def calls(pid), do: GenServer.call(pid, :calls)

    def handle_call(:max_concurrent_agents, _from, state) do
      {:reply, %{active: 0, paused: 0, configured: 2, max: state.max, session_override?: true}, state}
    end

    def handle_call({:pause_agent, identifier}, _from, state) do
      {:reply, {:ok, 101}, record_call(state, {:pause, identifier})}
    end

    def handle_call({:resume_agent, identifier}, _from, state) do
      {:reply, state.resume_result, record_call(state, {:resume, identifier})}
    end

    def handle_call({:adjust_max_concurrent_agents, delta}, _from, %{adjust_result: nil} = state) do
      next = max(state.max + delta, 1)
      state = state |> record_call({:adjust_max, delta}) |> Map.put(:max, next)
      {:reply, {:ok, %{active: 0, paused: 0, configured: 2, max: next, session_override?: true}}, state}
    end

    def handle_call({:adjust_max_concurrent_agents, delta}, _from, state) do
      {:reply, state.adjust_result, record_call(state, {:adjust_max, delta})}
    end

    def handle_call({:set_remote_control, identifier, on?}, _from, state) do
      {:reply, state.rc_result, record_call(state, {:set_remote_control, identifier, on?})}
    end

    def handle_call({:await_call, call}, from, state) do
      if MapSet.member?(state.calls, call) do
        {:reply, :ok, state}
      else
        {:noreply, update_in(state.call_waiters[call], fn waiters -> [from | waiters || []] end)}
      end
    end

    def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

    def handle_cast({:set_resume_result, result}, state), do: {:noreply, %{state | resume_result: result}}
    def handle_cast({:set_adjust_result, result}, state), do: {:noreply, %{state | adjust_result: result}}
    def handle_cast({:set_rc_result, result}, state), do: {:noreply, %{state | rc_result: result}}

    defp record_call(state, call) do
      state.call_waiters
      |> Map.get(call, [])
      |> Enum.each(&GenServer.reply(&1, :ok))

      %{state | calls: MapSet.put(state.calls, call), call_waiters: Map.delete(state.call_waiters, call)}
    end
  end
end
