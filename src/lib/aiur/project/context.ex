defmodule Aiur.Project.Context do
  @moduledoc """
  The project the current process works for. With no context everything behaves
  as the single-project runtime always has.

  The context is explicit (`put/1`) and per process. Resolution through
  `$callers`/`$ancestors` arrives with the project registry (MPG-306); until
  then use `Aiur.Project.Task.async/1` to hand a context to a task.
  """
  @key {__MODULE__, :project}

  @spec put(Aiur.Project.t()) :: :ok
  def put(%Aiur.Project{} = project) do
    Process.put(@key, project)
    :ok
  end

  @spec current() :: Aiur.Project.t() | nil
  def current, do: Process.get(@key)

  @spec current_id() :: Aiur.Project.id() | nil
  def current_id do
    case current() do
      %Aiur.Project{id: id} -> id
      nil -> nil
    end
  end

  @spec delete() :: :ok
  def delete do
    Process.delete(@key)
    :ok
  end

  @doc "Runs `fun` with no project context, restoring the previous one after."
  @spec without((-> result)) :: result when result: var
  def without(fun) do
    previous = Process.delete(@key)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous)
    end
  end
end
