defmodule Aiur.AppServer.ProviderTurnLedger do
  @moduledoc """
  Tracks provider-confirmed, accepted, and retired turn identifiers.

  Active and accepted identifiers belong to one Aiur turn. Retired identifiers
  and the anonymous-completion guard persist for the lifetime of a reused
  app-server session so late frames cannot affect a later turn.
  """

  @type store :: pid()

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
    Agent.get(store, & &1)
  catch
    :exit, _reason -> default_guards()
  end

  def guards(_store), do: default_guards()

  @spec start_turn(store() | nil) :: map()
  def start_turn(store) do
    guards(store)
    |> Map.merge(%{
      active_turn_ids: MapSet.new(),
      accepted_turn_ids: MapSet.new(),
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
    %{
      state
      | accepted_turn_ids: MapSet.new(),
        anonymous_completion_consumed?: true,
        retired_turn_ids:
          state.retired_turn_ids
          |> MapSet.union(state.active_turn_ids)
          |> MapSet.union(state.accepted_turn_ids)
    }
    |> put_active_turn_ids(MapSet.new())
    |> persist_guards()
  end

  @spec retire_all(map()) :: map()
  def retire_all(state) do
    %{
      state
      | active_turn_ids: MapSet.new(),
        accepted_turn_ids: MapSet.new(),
        anonymous_completion_consumed?: true,
        retired_turn_ids:
          state.retired_turn_ids
          |> MapSet.union(state.active_turn_ids)
          |> MapSet.union(state.accepted_turn_ids),
        outstanding_turns: 0
    }
    |> persist_guards()
  end

  defp retire_completion(state, turn_id) when is_binary(turn_id) do
    {retire_identified(state, turn_id), turn_id}
  end

  defp retire_completion(%{anonymous_completion_consumed?: true} = state, nil), do: {state, nil}

  defp retire_completion(state, nil) do
    consumed_state = %{state | anonymous_completion_consumed?: true}

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

  @spec put_active_turn_ids(map(), MapSet.t()) :: map()
  defp put_active_turn_ids(state, active_turn_ids) do
    %{state | active_turn_ids: active_turn_ids, outstanding_turns: Enum.count(active_turn_ids)}
  end

  defp persist_guards(%{provider_turn_store: store} = state) when is_pid(store) do
    guards = Map.take(state, [:retired_turn_ids, :anonymous_completion_consumed?])
    Agent.update(store, fn _previous -> guards end)
    state
  catch
    :exit, _reason -> state
  end

  defp persist_guards(state), do: state

  defp default_guards do
    %{retired_turn_ids: MapSet.new(), anonymous_completion_consumed?: false}
  end
end
