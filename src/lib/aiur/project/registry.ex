defmodule Aiur.Project.Registry do
  @moduledoc """
  Lookups over `Aiur.ProjectRegistry`, the machine-level `Registry` every project
  tree registers in. A project root registers `{id, Aiur.Project.Supervisor}` with
  its `%Aiur.Project{}` as the value; ids are always the downcased repo.
  """

  @registry Aiur.ProjectRegistry

  @spec via(Aiur.Project.id(), module()) :: GenServer.name()
  def via(project_id, module), do: {:via, Registry, {@registry, {String.downcase(project_id), module}}}

  @doc "Registers the calling process as the root of `project`."
  @spec register_root(Aiur.Project.t()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register_root(%Aiur.Project{id: id} = project), do: Registry.register(@registry, {id, Aiur.Project.Supervisor}, project)

  @spec root_pid(Aiur.Project.id()) :: pid() | nil
  def root_pid(project_id) do
    case lookup(project_id) do
      [{pid, _project}] -> pid
      [] -> nil
    end
  end

  @spec project(Aiur.Project.id()) :: Aiur.Project.t() | nil
  def project(project_id) do
    case lookup(project_id) do
      [{_pid, project}] -> project
      [] -> nil
    end
  end

  @spec project_ids() :: [Aiur.Project.id()]
  def project_ids do
    if Process.whereis(@registry) do
      @registry
      |> Registry.select([{{{:"$1", Aiur.Project.Supervisor}, :_, :_}, [], [:"$1"]}])
      |> Enum.sort()
    else
      []
    end
  end

  defp lookup(project_id) do
    if Process.whereis(@registry), do: Registry.lookup(@registry, {String.downcase(project_id), Aiur.Project.Supervisor}), else: []
  end
end
