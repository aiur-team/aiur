defmodule Aiur.Project.ConfigTest do
  use ExUnit.Case, async: false

  alias Aiur.Application.Children
  alias Aiur.Application.ProjectChildren
  alias Aiur.Project
  alias Aiur.Project.Config
  alias Aiur.Project.Config.ConfigError
  alias Aiur.Project.{Registry, Supervisors, Table, Watcher}
  alias Aiur.TestSupport.WorkflowFiles

  import Aiur.DispatcherTestSupport, only: [wait_until: 2]

  setup do
    dir = Path.join(System.tmp_dir!(), "project-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:aiur, :machine_settings_path)
    Application.put_env(:aiur, :machine_settings_path, Path.join(dir, "machine"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :machine_settings_path, previous), else: Application.delete_env(:aiur, :machine_settings_path)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp write_machine(dir, yaml), do: File.write!(Path.join(dir, "machine"), yaml)

  defp shape, do: [interactive_cli?: false, headless?: true, dashboard?: false]

  defp modules(children),
    do:
      Enum.map(children, fn
        {module, _} -> module
        %{id: id} -> id
        module -> module
      end)

  test "a missing machine file means no projects" do
    assert Config.configured() == []
  end

  test "each entry becomes a project with a sibling state leaf named by the downcased repo", %{dir: dir} do
    write_machine(dir, "projects:\n  - repo: O/Alpha\n    config: /x/alpha/config\n  - repo: o/beta\n    config: /x/beta/config\n")

    assert [%{id: "o/alpha", repo: "O/Alpha", state_root: alpha}, %{id: "o/beta", state_root: beta}] = Config.configured()
    assert Path.basename(alpha) == "alpha"
    assert Path.dirname(alpha) == Path.dirname(beta)
  end

  test "an invalid machine file refuses instead of falling back, without printing the path", %{dir: dir} do
    write_machine(dir, "projects:\n  - repo: nope\n    config: /secret/place\n")

    error = assert_raise ConfigError, &Config.configured/0
    assert error.message =~ "projects"
    refute error.message =~ "/secret/place"
  end

  test "two repos sharing a state leaf refuse", %{dir: dir} do
    write_machine(dir, "projects:\n  - repo: x/api\n    config: /x/a\n  - repo: y/api\n    config: /y/a\n")

    error = assert_raise ConfigError, &Config.configured/0
    assert error.message =~ "x/api" and error.message =~ "y/api"
  end

  test "no projects leaves the single-project tree" do
    children = modules(Children.child_specs(shape() ++ [projects: []]))

    assert Enum.count(children, &(&1 == Aiur.Orchestrator)) == 1
    assert Aiur.GitHub.Listeners in children
    refute Enum.any?([Supervisors, Watcher, Aiur.Project.Boot], &(&1 in children))
  end

  @tag capture_log: true
  test "project trees come back after a machine child ahead of them crashes", %{dir: dir} do
    config = Path.join([dir, "repo", ".aiur", "config"])
    File.mkdir_p!(Path.dirname(config))
    WorkflowFiles.write_workflow_file!(config, tracker_kind: "memory")
    write_machine(dir, "projects:\n  - repo: o/boot\n    config: #{config}\n")
    on_exit(fn -> Table.drop("o/boot") end)

    machine = %{id: :machine_child, start: {Agent, :start_link, [fn -> nil end]}}
    me = self()
    watcher = {Watcher, alert_fun: fn name, opts -> send(me, {:alert, name, opts[:message]}) end}
    tree = [machine, Supervisors, watcher, Supervisors.boot_child_spec([])]
    sup = start_supervised!(%{id: :machine, start: {Supervisor, :start_link, [tree, [strategy: :rest_for_one]]}, type: :supervisor})

    first = wait_for_root("o/boot")
    [{_, agent, _, _}] = Enum.filter(Supervisor.which_children(sup), &(elem(&1, 0) == :machine_child))
    Process.exit(agent, :kill)

    assert wait_for_root("o/boot", first) != first
  end

  defp wait_for_root(id, not_pid \\ nil) do
    wait_until(fn -> Registry.root_pid(id) not in [nil, not_pid] end, 300)
    Registry.root_pid(id)
  end

  test "projects drop the machine pollers and start one tree per project last" do
    project = Project.from_machine_entry(%{repo: "o/a", config: "/x/config"}, "/x/state")
    children = modules(Children.child_specs(shape() ++ [projects: [project]]))

    refute Enum.any?(ProjectChildren.pollers(), &(&1 in children))
    assert Enum.take(children, -3) == [Supervisors, Watcher, Aiur.Project.Boot]
    # Machine-level stores stay ahead of the project trees.
    assert Enum.find_index(children, &(&1 == Aiur.WorkflowStore)) < Enum.find_index(children, &(&1 == Supervisors))
  end
end
