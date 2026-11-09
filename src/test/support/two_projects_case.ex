defmodule Aiur.TwoProjectsCase do
  @moduledoc """
  Starts projects `o/a` and `o/b` as real project trees on a memory tracker, each with its
  own state root under a temp directory. Never touches `~/.aiur`.
  """
  use ExUnit.CaseTemplate

  alias Aiur.Orchestrator.PauseGuard
  alias Aiur.Project
  alias Aiur.Project.{Context, Supervisors, Table, Watcher}
  alias Aiur.TestSupport.WorkflowFiles

  using do
    quote do
      import Aiur.TwoProjectsCase
      alias Aiur.Project
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "two-projects-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :gateway_pause_store_path)
    Application.put_env(:aiur, :gateway_pause_store_path, Path.join(root, "gateway-pause.json"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :gateway_pause_store_path, previous),
        else: Application.delete_env(:aiur, :gateway_pause_store_path)

      Enum.each(["o/a", "o/b"], &Table.drop/1)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    start_supervised!(Supervisors)
    start_supervised!({Watcher, alert_fun: fn _name, _opts -> :ok end})
    projects = for repo <- ["o/a", "o/b"], into: %{}, do: {repo, project(repo, root)}
    for {_repo, p} <- projects, do: {:ok, _} = Supervisors.start_project(p)
    {:ok, a: projects["o/a"], b: projects["o/b"], root: root}
  end

  def project(repo, root) do
    state_root = Path.join(root, String.replace(repo, "/", "-"))
    config = Path.join([state_root, "repo", ".aiur", "config"])
    File.mkdir_p!(Path.dirname(config))
    WorkflowFiles.write_workflow_file!(config, tracker_kind: "memory")
    Project.from_machine_entry(%{repo: repo, config: config}, state_root)
  end

  @doc "Runs `fun` in a process working for `project`."
  def in_project(%Project{} = project, fun) do
    Task.async(fn ->
      Context.put(project)
      fun.()
    end)
    |> Task.await(15_000)
  end

  def orchestrator(%Project{id: id}), do: GenServer.whereis(Project.name(Aiur.Orchestrator, id))

  def orchestrator_state(%Project{} = project), do: :sys.get_state(orchestrator(project))

  def dispatch_paused?(%Project{} = project), do: PauseGuard.paused?(orchestrator_state(project))

  @doc "Polls `fun` until it returns a truthy value (bounded, no fixed sleep)."
  def eventually(fun, tries \\ 100) do
    cond do
      result = fun.() -> result
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
