defmodule Aiur.GitHub.BudgetBroker do
  @moduledoc "Owns the daemon's persistent, correlated budget broker port."
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec command(GenServer.server(), String.t(), [String.t()], integer()) :: term()
  def command(server, broker, args, deadline_at) do
    # The timer belongs to the port owner, so expired responses cannot be read
    # as the next caller's response. No timeout kills another caller's work.
    GenServer.call(server, {:command, broker, args, deadline_at}, :infinity)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{python: Keyword.get(opts, :python, System.find_executable("python3")), port: nil, pending: %{}, next_id: 0, buffer: ""}}
  end

  @impl true
  def handle_call({:command, broker, args, deadline_at}, from, state) do
    remaining = deadline_at - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:reply, :timeout, state}
    else
      enqueue(state, broker, args, remaining, from)
    end
  end

  defp enqueue(state, broker, args, remaining, from) do
    id = state.next_id
    enqueue_request(%{state | next_id: id + 1}, broker, args, remaining, from, id)
  end

  defp enqueue_request(state, broker, args, remaining, from, id) do
    payload = Jason.encode!(%{id: id, args: args, deadline_ms: System.system_time(:millisecond) + remaining}) <> "\n"
    state = ensure_port(state, broker)
    timer = Process.send_after(self(), {:deadline, id}, remaining)
    next = %{state | pending: Map.put(state.pending, id, {from, timer})}
    send_request(next, payload, id)
  rescue
    _error -> {:reply, :timeout, state}
  end

  defp send_request(state, payload, id) do
    if Port.command(state.port, payload, [:nosuspend]), do: {:noreply, state}, else: {:noreply, complete(state, id, :timeout)}
  rescue
    _error -> {:noreply, fail_pending(state)}
  end

  defp ensure_port(%{port: nil} = state, broker) do
    port = Port.open({:spawn_executable, String.to_charlist(state.python)}, [:binary, :exit_status, :use_stdio, args: [broker, "serve"]])
    %{state | port: port, buffer: ""}
  end

  defp ensure_port(state, _broker), do: state

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    lines = String.split(state.buffer <> data, "\n")
    {complete, [buffer]} = Enum.split(lines, -1)
    {:noreply, Enum.reduce(complete, %{state | buffer: buffer}, &reply_line/2)}
  end

  def handle_info({:deadline, id}, state), do: {:noreply, complete(state, id, :timeout)}

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    state = Enum.reduce(Map.keys(state.pending), state, &complete(&2, &1, :timeout))
    {:noreply, %{state | port: nil, buffer: ""}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reply_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "output" => output, "status" => status}} -> complete(state, id, if(status == 2, do: :timeout, else: {:ok, output, status}))
      _invalid -> fail_pending(state, {:error, :invalid_broker_reply})
    end
  end

  defp fail_pending(state, result \\ :timeout) do
    if Port.info(state.port), do: Port.close(state.port)
    state = Enum.reduce(Map.keys(state.pending), state, &complete(&2, &1, result))
    %{state | port: nil, buffer: ""}
  end

  defp complete(state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, result)
        %{state | pending: pending}
    end
  end
end
