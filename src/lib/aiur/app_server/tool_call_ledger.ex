defmodule Aiur.AppServer.ToolCallLedger do
  @moduledoc """
  Keeps dynamic-tool results stable across app-server generations.

  Codex can replay a `callId` after its port dies before Aiur writes the
  response. The first generation may already have performed the mutation, so
  later generations must reuse that result instead of executing it again.
  """

  use GenServer

  @max_completed 2_048

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec execute(term(), term(), (-> result), GenServer.server()) :: result when result: term()
  def execute(scope, call_id, fun, server \\ __MODULE__)

  def execute(scope, call_id, fun, server)
      when not is_nil(scope) and not is_nil(call_id) and is_function(fun, 0) do
    key = {scope, call_id}

    case GenServer.call(server, {:claim, key}, :infinity) do
      {:cached, result} -> result
      {:execute, token} -> execute_claim(server, key, token, fun)
      :retry -> execute(scope, call_id, fun, server)
    end
  end

  def execute(_scope, _call_id, fun, _server) when is_function(fun, 0), do: fun.()

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}, completed: :queue.new()}}

  @impl true
  def handle_call({:claim, key}, from, state) do
    case Map.get(state.entries, key) do
      {:done, result} ->
        {:reply, {:cached, result}, state}

      {:running, token, owner, monitor, waiters} ->
        entry = {:running, token, owner, monitor, [from | waiters]}
        {:noreply, put_in(state.entries[key], entry)}

      nil ->
        owner = elem(from, 0)
        token = make_ref()
        monitor = Process.monitor(owner)
        entry = {:running, token, owner, monitor, []}
        {:reply, {:execute, token}, put_in(state.entries[key], entry)}
    end
  end

  def handle_call({:complete, key, token, result}, _from, state) do
    case Map.get(state.entries, key) do
      {:running, ^token, _owner, monitor, waiters} ->
        Process.demonitor(monitor, [:flush])
        Enum.each(waiters, &GenServer.reply(&1, {:cached, result}))

        next_state =
          state
          |> put_in([:entries, key], {:done, result})
          |> Map.update!(:completed, &:queue.in(key, &1))
          |> trim_completed()

        {:reply, :ok, next_state}

      _other ->
        {:reply, {:error, :stale_claim}, state}
    end
  end

  def handle_call({:abandon, key, token}, _from, state) do
    {:reply, :ok, abandon_claim(state, key, token)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case Enum.find(state.entries, fn
           {_key, {:running, _token, ^owner, ^monitor, _waiters}} -> true
           _entry -> false
         end) do
      {key, {:running, token, ^owner, ^monitor, _waiters}} ->
        {:noreply, abandon_claim(state, key, token)}

      nil ->
        {:noreply, state}
    end
  end

  defp execute_claim(server, key, token, fun) do
    result = fun.()
    :ok = GenServer.call(server, {:complete, key, token, result}, :infinity)
    result
  catch
    kind, reason ->
      _ = GenServer.call(server, {:abandon, key, token}, :infinity)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp abandon_claim(state, key, token) do
    case Map.get(state.entries, key) do
      {:running, ^token, _owner, monitor, waiters} ->
        Process.demonitor(monitor, [:flush])
        Enum.each(waiters, &GenServer.reply(&1, :retry))
        update_in(state.entries, &Map.delete(&1, key))

      _other ->
        state
    end
  end

  defp trim_completed(%{entries: entries} = state) when map_size(entries) <= @max_completed,
    do: state

  defp trim_completed(state) do
    case :queue.out(state.completed) do
      {{:value, key}, completed} ->
        state
        |> Map.put(:completed, completed)
        |> update_in([:entries], &delete_completed(&1, key))
        |> trim_completed()

      {:empty, _completed} ->
        state
    end
  end

  defp delete_completed(entries, key) do
    case Map.get(entries, key) do
      {:done, _result} -> Map.delete(entries, key)
      _other -> entries
    end
  end
end
