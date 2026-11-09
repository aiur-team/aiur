defmodule Aiur.Project.Supervisor do
  @moduledoc """
  Root of one project tree. It registers itself in `Aiur.ProjectRegistry` before
  starting its children, so they and their tasks resolve the project from
  `$ancestors`/`$callers` (`Aiur.Project.Context`).

  `:rest_for_one` because the list is in dependency order. Three restarts in five
  seconds is a crash loop: the root exits and `Aiur.Project.Watcher` alerts.
  """
  use Supervisor

  alias Aiur.Application.ProjectChildren
  alias Aiur.Project.{Context, Registry}

  @spec start_link(Aiur.Project.t(), keyword()) :: Supervisor.on_start()
  def start_link(%Aiur.Project{} = project, opts \\ []), do: Supervisor.start_link(__MODULE__, {project, opts})

  @impl true
  def init({project, opts}) do
    case register(project, 100) do
      {:ok, _owner} ->
        Context.put(project)
        Supervisor.init(ProjectChildren.specs(project, opts), strategy: :rest_for_one, max_restarts: 3, max_seconds: 5)

      {:error, {:already_registered, _pid}} ->
        {:stop, :already_started}
    end
  end

  # A tree restarted right after its predecessor died can find the dead root's key
  # still held: the registry releases it on its own `DOWN`, after the children's keys.
  defp register(project, tries) do
    case Registry.register_root(project) do
      {:error, {:already_registered, pid}} when tries > 0 ->
        if Process.alive?(pid) do
          {:error, {:already_registered, pid}}
        else
          Process.sleep(10)
          register(project, tries - 1)
        end

      result ->
        result
    end
  end
end
