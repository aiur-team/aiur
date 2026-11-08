defmodule Aiur.Project.Supervisor do
  @moduledoc """
  Root of one project tree. It registers itself in `Aiur.ProjectRegistry` before
  starting its children, so they and their tasks resolve the project from
  `$ancestors`/`$callers` (`Aiur.Project.Context`).

  `:rest_for_one` because the list is in dependency order. Three restarts in five
  seconds is a crash loop: the root exits and `Aiur.Project.Watcher` alerts.
  """
  use Supervisor

  @spec start_link(Aiur.Project.t(), keyword()) :: Supervisor.on_start()
  def start_link(%Aiur.Project{} = project, opts \\ []), do: Supervisor.start_link(__MODULE__, {project, opts})

  @impl true
  def init({project, opts}) do
    case Aiur.Project.Registry.register_root(project) do
      {:ok, _owner} ->
        Aiur.Project.Context.put(project)
        Supervisor.init(Aiur.Project.Children.specs(project, opts), strategy: :rest_for_one, max_restarts: 3, max_seconds: 5)

      {:error, {:already_registered, _pid}} ->
        {:stop, :already_started}
    end
  end
end
