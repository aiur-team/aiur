defmodule Aiur.Orchestrator.TrackedSet do
  @moduledoc """
  Owns the orchestrator's hot-path ETS set of currently tracked issues.

  The table is read directly by the event publisher path, but writes are routed
  through this supervised process so a test or orchestrator restart cannot leave
  the named table owned by a short-lived caller.
  """

  use GenServer

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

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:reset, issue_ids}, _from, state) do
    {:reply, replace_all(issue_ids), state}
  end

  defp call(message) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, message)
    end
  catch
    :exit, _reason -> :ok
  end

  defp replace_all(issue_ids, attempts_left \\ 2) do
    ensure_table()
    :ets.delete_all_objects(@table)
    Enum.each(issue_ids, &:ets.insert(@table, {&1, true}))
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
