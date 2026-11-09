defmodule Aiur.Project.Context do
  @moduledoc """
  The project the current process works for. With no context everything behaves
  as the single-project runtime always has.

  An explicit `put/1` wins. Otherwise the project is resolved once per process
  from `$ancestors` and `$callers`: any of them registered in `Aiur.ProjectRegistry`
  under `{project_id, module}` names the project, so every child of a project tree
  and every task it starts works for that project without being told.
  """
  @key {__MODULE__, :project}
  @resolved {__MODULE__, :resolved}

  @spec put(Aiur.Project.t()) :: :ok
  def put(%Aiur.Project{} = project) do
    Process.put(@key, project)
    :ok
  end

  @spec current() :: Aiur.Project.t() | nil
  def current do
    case Process.get(@key) do
      %Aiur.Project{} = project -> project
      :none -> nil
      nil -> resolved()
    end
  end

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
    previous = Process.put(@key, :none)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  defp resolved do
    case Process.get(@resolved) do
      nil ->
        project = from_lineage()
        Process.put(@resolved, project || :none)
        project

      :none ->
        nil

      project ->
        project
    end
  end

  defp from_lineage do
    if Process.whereis(Aiur.ProjectRegistry) do
      Enum.find_value(Process.get(:"$ancestors", []) ++ Process.get(:"$callers", []), &project_of/1)
    end
  end

  defp project_of(name) when is_atom(name), do: name |> Process.whereis() |> project_of()

  defp project_of(pid) when is_pid(pid) do
    Enum.find_value(Registry.keys(Aiur.ProjectRegistry, pid), fn
      {id, _module} -> Aiur.Project.Registry.project(id)
      _other -> nil
    end)
  end

  defp project_of(_other), do: nil
end
