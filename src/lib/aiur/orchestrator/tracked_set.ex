defmodule Aiur.Orchestrator.TrackedSet do
  @moduledoc """
  Owns the orchestrator's hot-path ETS set of currently tracked issues.

  The table is read directly by the event publisher path, but writes are routed
  through this supervised process so a test or orchestrator restart cannot leave
  the named table owned by a short-lived caller.
  """

  use GenServer

  alias Aiur.{Issue, Orchestrator.TrackerIdentityStore}
  alias Aiur.Orchestrator.State

  @table __MODULE__
  @identity_table Module.concat(__MODULE__, Identity)
  @table_opts [
    :named_table,
    :public,
    :set,
    read_concurrency: true,
    write_concurrency: true
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec reset([String.t() | integer()]) :: :ok
  def reset(issue_ids) when is_list(issue_ids) do
    issue_ids =
      issue_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    call({:reset, issue_ids})
  end

  @spec member?(String.t() | integer() | nil) :: boolean()
  def member?(nil), do: false

  def member?(issue_number) do
    case :ets.whereis(@table) do
      :undefined -> true
      _table -> :ets.member(@table, to_string(issue_number))
    end
  rescue
    ArgumentError -> true
  end

  @spec tracker_identity(String.t() | integer() | nil) :: Aiur.TrackerIdentity.t() | nil
  def tracker_identity(nil), do: nil

  def tracker_identity(identifier) do
    case :ets.lookup(@identity_table, to_string(identifier)) do
      [{_identifier, %Aiur.TrackerIdentity{} = identity}] -> identity
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec refresh(State.t()) :: State.t()
  def refresh(%State{} = state) do
    entries = Enum.map(state.running, fn {_id, entry} -> {entry[:identifier] || Map.get(entry, :identifier), Issue.tracker_identity(Map.get(entry, :issue))} end)
    identities = Enum.reject(entries, fn {identifier, identity} -> is_nil(identifier) or is_nil(identity) end)

    # Membership rejects late worker events after deactivation. Identity is a
    # separate durable snapshot: PR lifecycle events can arrive after handoff
    # or after an orchestrator restart without another tracker read.
    active_entries =
      Enum.reject(state.running, fn {_id, entry} -> get_in(entry, [:control, :status]) == :deactivated end)
      |> Enum.map(fn {_id, entry} -> {entry[:identifier] || Map.get(entry, :identifier), true} end)
      |> Enum.reject(fn {identifier, _member} -> is_nil(identifier) end)

    call({:refresh, active_entries, identities})
    state
  end

  @impl true
  def init(_opts) do
    ensure_table()
    ensure_identity_table()
    identities = TrackerIdentityStore.load()
    replace_all(@identity_table, Map.to_list(identities))
    {:ok, %{identities: identities}}
  end

  @impl true
  def handle_call({:reset, issue_ids}, _from, state) do
    :ets.delete_all_objects(@identity_table)
    :ok = TrackerIdentityStore.save(%{})
    {:reply, replace_all(@table, issue_ids), %{state | identities: %{}}}
  end

  def handle_call({:refresh, active_entries, identities}, _from, state) do
    next_identities = Map.merge(state.identities, Map.new(identities, fn {identifier, identity} -> {to_string(identifier), identity} end))
    :ok = TrackerIdentityStore.save(next_identities)
    replace_all(@identity_table, Map.to_list(next_identities))
    {:reply, replace_all(@table, active_entries), %{identities: next_identities}}
  end

  defp call(message, attempts_left \\ 3) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, message)
    end
  catch
    # A busy-but-alive owner under host load can outlast the call's default
    # timeout; that is not the same as the owner genuinely being gone, so
    # retry rather than silently treating a lost write as a no-op. Any other
    # exit reason (e.g. :noproc) means the owner really isn't there, which is
    # the legitimate no-op case this helper exists to tolerate.
    :exit, {:timeout, _} when attempts_left > 1 -> call(message, attempts_left - 1)
    :exit, _reason -> :ok
  end

  defp replace_all(table, entries, attempts_left \\ 2) do
    ensure_table(table)
    :ets.delete_all_objects(table)

    Enum.each(entries, fn
      {identifier, value} -> :ets.insert(table, {to_string(identifier), value})
      identifier -> :ets.insert(table, {to_string(identifier), true})
    end)

    :ok
  rescue
    ArgumentError ->
      if attempts_left > 1 do
        replace_all(table, entries, attempts_left - 1)
      else
        :ok
      end
  end

  defp ensure_table(table \\ @table) do
    case :ets.whereis(table) do
      :undefined -> :ets.new(table, @table_opts)
      existing -> existing
    end
  end

  defp ensure_identity_table, do: ensure_table(@identity_table)
end
