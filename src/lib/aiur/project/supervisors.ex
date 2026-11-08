defmodule Aiur.Project.Supervisors do
  @moduledoc """
  The machine-level `DynamicSupervisor` holding one `Aiur.Project.Supervisor` per
  configured project.

  Roots are `:temporary`: a root that exits is never restarted here, so a
  crash-looping project cannot spend this supervisor's own restart intensity and
  take every other project down with it. `Aiur.Project.Watcher` alerts instead,
  and `reload/1` (`aiur gateway reload`) retries.
  """
  use DynamicSupervisor

  alias Aiur.Project
  alias Aiur.Project.{Registry, Watcher}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Boot child: starts every configured project once, then exits."
  @spec boot_child_spec([Project.t()], keyword()) :: Supervisor.child_spec()
  def boot_child_spec(projects, opts) do
    %{id: Aiur.Project.Boot, start: {Task, :start_link, [fn -> Enum.each(projects, &start_project(&1, opts)) end]}, restart: :temporary}
  end

  @spec start_project(Project.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_project(%Project{} = project, opts \\ []) do
    spec = %{id: project.id, start: {Project.Supervisor, :start_link, [project, opts]}, type: :supervisor, restart: :temporary}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        :ok = Watcher.started(project, pid)
        {:ok, pid}

      {:error, reason} ->
        :ok = Watcher.failed(project, reason)
        {:error, reason}
    end
  end

  @doc "Stops one project's tree; no other tree is touched."
  @spec stop_project(Project.id()) :: :ok | {:error, :not_found}
  def stop_project(project_id) do
    :ok = Watcher.stopping(project_id)

    case Registry.root_pid(project_id) do
      nil ->
        {:error, :not_found}

      pid ->
        _ = DynamicSupervisor.terminate_child(__MODULE__, pid)
        Project.Table.drop(String.downcase(project_id))
    end
  end

  @doc "Running and failed projects."
  @spec which_projects() :: [%{id: Project.id(), repo: String.t(), pid: pid() | nil, state: :running | :failed}]
  def which_projects do
    running =
      for id <- Registry.project_ids(), project = Registry.project(id), do: %{id: id, repo: project.repo, pid: Registry.root_pid(id), state: :running}

    failed = for {id, project} <- Watcher.failures(), do: %{id: id, repo: project.repo, pid: nil, state: :failed}
    Enum.sort_by(running ++ failed, & &1.id)
  end

  @doc """
  Brings the running trees in line with `projects`: starts the missing (a failed
  project counts as missing), stops the removed and leaves the rest alone.
  """
  @spec reload([Project.t()], keyword()) :: %{started: [Project.id()], stopped: [Project.id()], failed: [{Project.id(), term()}], unchanged: [Project.id()]}
  def reload(projects \\ Project.Config.configured(), opts \\ []) do
    running = Registry.project_ids()
    wanted = Enum.map(projects, & &1.id)
    stopped = running -- wanted
    Enum.each(stopped, &stop_project/1)
    Enum.each(Map.keys(Watcher.failures()) -- wanted, &Watcher.stopping/1)

    {started, failed} =
      projects
      |> Enum.reject(&(&1.id in running))
      |> Enum.map(&{&1.id, start_project(&1, opts)})
      |> Enum.split_with(&match?({_id, {:ok, _pid}}, &1))

    %{
      started: Enum.map(started, &elem(&1, 0)),
      stopped: stopped,
      failed: Enum.map(failed, fn {id, {:error, reason}} -> {id, reason} end),
      unchanged: Enum.filter(wanted, &(&1 in running))
    }
  end
end
