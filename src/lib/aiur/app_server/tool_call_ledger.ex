defmodule Aiur.AppServer.ToolCallLedger do
  @moduledoc """
  Keeps dynamic-tool outcomes stable across app-server generations.

  A claim is persisted before its tool executes. Completed results are
  persisted before the provider response is written, while an owner or ledger
  failure leaves a durable uncertain tombstone that refuses re-execution.
  """

  use GenServer

  alias Aiur.AppServer.ToolCallLedger.Storage

  @type identity :: term()
  @type fingerprint :: binary()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec execute(identity() | nil, fingerprint() | nil, (-> result), GenServer.server()) ::
          result | {:error, term()}
        when result: term()
  def execute(identity, fingerprint, fun, server \\ __MODULE__)

  def execute(nil, _fingerprint, fun, _server) when is_function(fun, 0), do: fun.()
  def execute(_identity, nil, _fun, _server), do: {:error, :invalid_fingerprint}

  def execute(identity, fingerprint, fun, server)
      when is_binary(fingerprint) and is_function(fun, 0) do
    case GenServer.call(server, {:claim, identity, fingerprint}, :infinity) do
      {:cached, result} -> result
      {:execute, token} -> execute_claim(server, identity, token, fun)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    durable? = Keyword.has_key?(opts, :storage_path) or Keyword.get(opts, :name, __MODULE__) != nil

    with {:ok, storage} <- Storage.open(opts, durable?),
         {:ok, stored_entries} <- Storage.load(storage),
         {:ok, entries} <- recover_entries(stored_entries, storage) do
      {:ok, %{entries: entries, monitors: %{}, storage: storage}}
    else
      {:error, reason} -> {:stop, {:tool_call_ledger_storage, reason}}
    end
  end

  @impl true
  def handle_call({:claim, key, fingerprint}, from, state) do
    case Map.get(state.entries, key) do
      {:done, ^fingerprint, result} ->
        {:reply, {:cached, result}, state}

      {:uncertain, ^fingerprint} ->
        {:reply, {:error, :outcome_uncertain}, state}

      {:running, ^fingerprint, token, owner, monitor, waiters} ->
        entry = {:running, fingerprint, token, owner, monitor, [from | waiters]}
        {:noreply, put_in(state.entries[key], entry)}

      nil ->
        claim_new(state, key, fingerprint, from)

      _conflicting ->
        {:reply, {:error, :conflicting_invocation}, state}
    end
  end

  def handle_call({:complete, key, token, result}, _from, state) do
    case Map.get(state.entries, key) do
      {:running, fingerprint, ^token, _owner, _monitor, _waiters} ->
        case Storage.put(state.storage, key, {:done, fingerprint, result}) do
          :ok -> {:reply, :ok, complete_claim(state, key, result)}
          {:error, _reason} -> {:reply, {:error, :outcome_uncertain}, mark_uncertain(state, key, token)}
        end

      _other ->
        {:reply, {:error, :outcome_uncertain}, state}
    end
  end

  def handle_call({:mark_uncertain, key, token}, _from, state) do
    {:reply, :ok, mark_uncertain(state, key, token)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {{key, token}, monitors} ->
        {:noreply, mark_uncertain(%{state | monitors: monitors}, key, token)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Storage.close(state.storage)
  end

  defp claim_new(state, key, fingerprint, from) do
    owner = elem(from, 0)
    token = make_ref()
    monitor = Process.monitor(owner)
    entry = {:running, fingerprint, token, owner, monitor, []}

    case Storage.put(state.storage, key, {:running, fingerprint}) do
      :ok ->
        next_state =
          state
          |> put_in([:entries, key], entry)
          |> put_in([:monitors, monitor], {key, token})

        {:reply, {:execute, token}, next_state}

      {:error, reason} ->
        Process.demonitor(monitor, [:flush])
        {:reply, {:error, {:ledger_unavailable, reason}}, state}
    end
  end

  defp complete_claim(state, key, result) do
    {:running, fingerprint, _token, _owner, monitor, waiters} = Map.fetch!(state.entries, key)
    Process.demonitor(monitor, [:flush])
    Enum.each(waiters, &GenServer.reply(&1, {:cached, result}))

    state
    |> put_in([:entries, key], {:done, fingerprint, result})
    |> update_in([:monitors], &Map.delete(&1, monitor))
  end

  defp mark_uncertain(state, key, token) do
    case Map.get(state.entries, key) do
      {:running, fingerprint, ^token, _owner, monitor, waiters} ->
        _ = Storage.put(state.storage, key, {:uncertain, fingerprint})
        Process.demonitor(monitor, [:flush])
        Enum.each(waiters, &GenServer.reply(&1, {:error, :outcome_uncertain}))

        state
        |> put_in([:entries, key], {:uncertain, fingerprint})
        |> update_in([:monitors], &Map.delete(&1, monitor))

      _other ->
        state
    end
  end

  defp execute_claim(server, key, token, fun) do
    result = fun.()

    case GenServer.call(server, {:complete, key, token, result}, :infinity) do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  catch
    kind, reason ->
      mark_uncertain_safely(server, key, token)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp mark_uncertain_safely(server, key, token) do
    GenServer.call(server, {:mark_uncertain, key, token}, :infinity)
  catch
    :exit, _reason -> :ok
  end

  defp recover_entries(entries, storage) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      {key, {:running, fingerprint}}, {:ok, recovered} ->
        case Storage.put(storage, key, {:uncertain, fingerprint}) do
          :ok -> {:cont, {:ok, Map.put(recovered, key, {:uncertain, fingerprint})}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {key, {:done, fingerprint, result}}, {:ok, recovered} ->
        {:cont, {:ok, Map.put(recovered, key, {:done, fingerprint, result})}}

      {key, {:uncertain, fingerprint}}, {:ok, recovered} ->
        {:cont, {:ok, Map.put(recovered, key, {:uncertain, fingerprint})}}

      {key, _invalid}, _acc ->
        {:halt, {:error, {:invalid_entry, key}}}
    end)
  end
end
