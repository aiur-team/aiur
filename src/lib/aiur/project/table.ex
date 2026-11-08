defmodule Aiur.Project.Table do
  @moduledoc """
  ETS tables that are per project. With a project context the table is unnamed and
  found through `ref/1`; with none it is the named table the single-project runtime
  always had.
  """

  alias Aiur.Project.Context

  @doc "Creates the table; the project case records its tid for `ref/1`, reusing a live one."
  @spec new(atom(), [term()]) :: :ets.table()
  def new(name, opts), do: new(Context.current_id(), name, opts)

  defp new(nil, name, opts) do
    if :ets.whereis(name) == :undefined, do: :ets.new(name, [:named_table | opts]), else: name
  end

  defp new(id, name, opts) do
    key = {__MODULE__, id, name}
    tid = :persistent_term.get(key, nil)
    if tid && :ets.info(tid) != :undefined, do: tid, else: create(key, name, opts)
  end

  @doc "The table to read: the current project's tid, or `name` with no context. Unknown tables are `nil`, which `:ets` rejects with `ArgumentError`."
  @spec ref(atom()) :: :ets.table() | nil
  def ref(name) do
    case Context.current_id() do
      nil -> name
      id -> :persistent_term.get({__MODULE__, id, name}, nil)
    end
  end

  @doc "Forgets every table of `project_id`; called when the project stops."
  @spec drop(Aiur.Project.id()) :: :ok
  def drop(project_id) do
    for {{__MODULE__, ^project_id, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end

  defp create(key, name, opts) do
    tid = :ets.new(name, opts)
    :persistent_term.put(key, tid)
    tid
  end
end
