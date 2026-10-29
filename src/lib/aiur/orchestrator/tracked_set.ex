defmodule Aiur.Orchestrator.TrackedSet do
  @moduledoc """
  Owns the orchestrator's hot-path ETS set of currently tracked issues.

  The table is read directly by the event publisher path, but writes are routed
  through this supervised process so a test or orchestrator restart cannot leave
  the named table owned by a short-lived caller.
  """

  use GenServer

  alias Aiur.Orchestrator.State

  @table __MODULE__
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
    case :ets.lookup(@table, to_string(identifier)) do
      [{_identifier, %Aiur.TrackerIdentity{} = identity}] -> identity
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec refresh(State.t()) :: State.t()
  def refresh(%State{} = state) do
    # Deactivated rows remain visible in state but must reject late publisher events.
    entries =
      state.running
      |> Enum.reject(fn {_id, entry} ->
        get_in(entry, [:control, :status]) == :deactivated
      end)
      |> Enum.map(fn {_id, entry} ->
        {entry[:identifier] || Map.get(entry, :identifier), Aiur.Issue.tracker_identity(Map.get(entry, :issue))}
      end)
      |> Enum.reject(fn {identifier, _identity} -> is_nil(identifier) end)

    call({:reset, entries})
    state
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:reset, issue_ids}, _from, state) do
    {:reply, replace_all(issue_ids), state}
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

  defp replace_all(issue_ids, attempts_left \\ 2) do
    ensure_table()
    :ets.delete_all_objects(@table)

    Enum.each(issue_ids, fn
      {identifier, identity} -> :ets.insert(@table, {to_string(identifier), identity})
      identifier -> :ets.insert(@table, {to_string(identifier), true})
    end)

    :ok
  rescue
    ArgumentError ->
      if attempts_left > 1 do
        replace_all(issue_ids, attempts_left - 1)
      else
        :ok
      end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, @table_opts)
      table -> table
    end
  end
end
