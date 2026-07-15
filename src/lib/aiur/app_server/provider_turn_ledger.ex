defmodule Aiur.AppServer.ProviderTurnLedger do
  @moduledoc """
  Tracks provider-confirmed, accepted, and retired turn identifiers.

  Active and accepted identifiers belong to one Aiur turn. Retired identifiers
  and the anonymous-completion guard persist for the lifetime of a reused
  app-server session so late frames cannot affect a later turn.
  """

  require Logger

  @type store :: pid()
  @type anonymous_completion_guard_action :: :arm | :consume | :preserve

  # The store is a private, owner-linked Agent whose state is required for
  # safe session reuse. A scheduler delay must not turn into a false "fresh
  # session" after Agent's default five-second call timeout.
  @store_timeout :infinity

  @spec start_store() :: {:ok, store()} | {:error, term()}
  def start_store, do: Agent.start_link(fn -> default_guards() end)

  @spec stop_store(store() | nil) :: :ok
  def stop_store(store) when is_pid(store) do
    if Process.alive?(store), do: Agent.stop(store, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def stop_store(_store), do: :ok

  @spec guards(store() | nil) :: map()
  def guards(store) when is_pid(store) do
    Agent.get(store, & &1, @store_timeout)
  catch
    :exit, reason ->
      log_store_unavailable(:read, reason)
      unavailable_guards()
  end

  def guards(_store), do: default_guards()

  @spec start_turn(store() | nil) :: map()
  def start_turn(store) do
    guards(store)
    |> Map.merge(%{
      active_turn_ids: MapSet.new(),
      accepted_turn_ids: MapSet.new(),
      pending_anonymous_completion?: false,
      provider_turn_store: store
    })
  end

  @spec initialize(map()) :: map()
  def initialize(%{active_turn_ids: %MapSet{} = active_turn_ids, current_turn_id: turn_id} = state)
      when is_binary(turn_id) do
    put_active_turn_ids(state, MapSet.put(active_turn_ids, turn_id))
  end

  def initialize(state), do: state

  @spec accept(map(), map()) :: map()
  def accept(state, %{"id" => turn_id} = turn) when is_binary(turn_id) do
    cond do
      not active_turn?(turn) ->
        retire_identified(state, turn_id)

      MapSet.member?(state.active_turn_ids, turn_id) or
          MapSet.member?(state.retired_turn_ids, turn_id) ->
        state

      true ->
        %{state | accepted_turn_ids: MapSet.put(state.accepted_turn_ids, turn_id)}
    end
  end

  def accept(state, _turn), do: state

  @spec retired?(map(), String.t()) :: boolean()
  def retired?(%{retired_turn_ids: %MapSet{} = retired_turn_ids}, turn_id)
      when is_binary(turn_id) do
    MapSet.member?(retired_turn_ids, turn_id)
  end

  def retired?(_state, _turn_id), do: false

  @spec register(map(), map()) :: map()
  def register(state, %{"id" => turn_id} = turn) when is_binary(turn_id) do
    cond do
      not active_turn?(turn) ->
        retire_identified(state, turn_id)

      retired?(state, turn_id) ->
        state

      true ->
        state
        |> Map.put(:accepted_turn_ids, MapSet.delete(state.accepted_turn_ids, turn_id))
        |> put_active_turn_ids(MapSet.put(state.active_turn_ids, turn_id))
    end
  end

  def register(state, _turn), do: state

  @spec complete(map(), map()) :: map()
  def complete(state, payload) do
    {next_state, retired_turn_id} = retire_completion(state, provider_turn_id(payload))

    next_state
    |> retire_unstarted_at_parent_boundary(retired_turn_id)
    |> persist_guards()
  end

  @spec complete_all(map()) :: map()
  def complete_all(state) do
    retired_turn_ids =
      state.retired_turn_ids
      |> MapSet.union(state.active_turn_ids)
      |> MapSet.union(state.accepted_turn_ids)

    state
    |> Map.merge(%{
      accepted_turn_ids: MapSet.new(),
      anonymous_completion_consumed?: true,
      pending_anonymous_completion?: false,
      retired_turn_ids: retired_turn_ids
    })
    |> put_active_turn_ids(MapSet.new())
    |> persist_guards()
  end

  @spec retire_all(map()) :: map()
  def retire_all(state), do: retire_all(state, :arm)

  @spec retire_all(map(), anonymous_completion_guard_action()) :: map()
  def retire_all(state, guard_action) do
    retired_turn_ids =
      state.retired_turn_ids
      |> MapSet.union(state.active_turn_ids)
      |> MapSet.union(state.accepted_turn_ids)

    state
    |> Map.merge(%{
      active_turn_ids: MapSet.new(),
      accepted_turn_ids: MapSet.new(),
      anonymous_completion_consumed?: apply_guard_action(state, guard_action),
      pending_anonymous_completion?: false,
      retired_turn_ids: retired_turn_ids,
      outstanding_turns: 0
    })
    |> persist_guards()
  end

  defp retire_completion(state, turn_id) when is_binary(turn_id) do
    next_state = retire_identified(state, turn_id)

    if turn_id == state.current_turn_id do
      {Map.put(next_state, :pending_anonymous_completion?, false), turn_id}
    else
      {next_state, turn_id}
    end
  end

  defp retire_completion(%{anonymous_completion_consumed?: true} = state, nil) do
    # The persisted guard owns one ambiguous late frame from the retired
    # generation. Keep that frame as a candidate until an idle or port-exit
    # boundary confirms that the active provider work is also terminal.
    next_state =
      state
      |> Map.put(:anonymous_completion_consumed?, false)
      |> Map.put(:pending_anonymous_completion?, true)

    {next_state, nil}
  end

  defp retire_completion(state, nil) do
    consumed_state =
      state
      |> Map.put(:anonymous_completion_consumed?, true)
      |> Map.put(:pending_anonymous_completion?, false)

    if MapSet.member?(state.active_turn_ids, state.current_turn_id) do
      {retire_identified(consumed_state, state.current_turn_id), state.current_turn_id}
    else
      {consumed_state, nil}
    end
  end

  defp retire_identified(state, turn_id) do
    state
    |> Map.put(:accepted_turn_ids, MapSet.delete(state.accepted_turn_ids, turn_id))
    |> Map.put(:retired_turn_ids, MapSet.put(state.retired_turn_ids, turn_id))
    |> put_active_turn_ids(MapSet.delete(state.active_turn_ids, turn_id))
    |> persist_guards()
  end

  defp retire_unstarted_at_parent_boundary(state, retired_turn_id)
       when retired_turn_id == state.current_turn_id do
    %{
      state
      | accepted_turn_ids: MapSet.new(),
        retired_turn_ids: MapSet.union(state.retired_turn_ids, state.accepted_turn_ids)
    }
  end

  defp retire_unstarted_at_parent_boundary(state, _retired_turn_id), do: state

  defp provider_turn_id(%{"params" => %{"turn" => %{"id" => turn_id}}}) when is_binary(turn_id), do: turn_id
  defp provider_turn_id(%{"turn" => %{"id" => turn_id}}) when is_binary(turn_id), do: turn_id
  defp provider_turn_id(_payload), do: nil

  defp active_turn?(%{"status" => status}) when is_binary(status), do: status == "inProgress"
  defp active_turn?(_turn), do: true

  defp apply_guard_action(_state, :arm), do: true
  defp apply_guard_action(_state, :consume), do: false

  defp apply_guard_action(%{anonymous_completion_consumed?: consumed?}, :preserve),
    do: consumed?

  @spec put_active_turn_ids(map(), MapSet.t()) :: map()
  defp put_active_turn_ids(state, active_turn_ids) do
    %{state | active_turn_ids: active_turn_ids, outstanding_turns: Enum.count(active_turn_ids)}
  end

  defp persist_guards(%{provider_turn_store: store} = state) when is_pid(store) do
    guards = Map.take(state, [:retired_turn_ids, :anonymous_completion_consumed?])
    Agent.update(store, fn _previous -> guards end, @store_timeout)
    state
  catch
    :exit, reason ->
      log_store_unavailable(:write, reason)
      Map.put(state, :anonymous_completion_consumed?, true)
  end

  defp persist_guards(state), do: state

  defp default_guards do
    %{retired_turn_ids: MapSet.new(), anonymous_completion_consumed?: false}
  end

  defp unavailable_guards do
    %{default_guards() | anonymous_completion_consumed?: true}
  end

  defp log_store_unavailable(operation, reason) do
    Logger.warning(
      "Provider turn ledger guard store unavailable during #{operation}; " <>
        "preserving the anonymous completion barrier: #{inspect(reason)}"
    )
  end
end
