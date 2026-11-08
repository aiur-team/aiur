defmodule Aiur.ConfigProjectTest do
  use Aiur.TestSupport

  alias Aiur.Config.SettingsSnapshot
  alias Aiur.Project
  alias Aiur.Project.Context

  setup do
    dir = Path.join(System.tmp_dir!(), "config-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    start_supervised!({Registry, keys: :unique, name: Aiur.ProjectRegistry})
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    projects =
      for repo <- ["o/a", "o/b"] do
        path = Path.join(dir, String.replace(repo, "/", "-") <> ".yaml")
        write_workflow_file!(path, tracker_kind: "github", tracker_repo: repo)
        Project.from_machine_entry(%{repo: repo, config: path}, dir)
      end

    [a, b] = projects
    %{a: a, b: b}
  end

  defp repo!, do: Aiur.Config.settings!().tracker.github.repo

  test "settings follow each process's project", %{a: a, b: b} do
    results =
      for p <- [a, b, a, b] do
        Task.async(fn ->
          Context.put(p)
          repo!()
        end)
      end
      |> Task.await_many()

    assert results == ["o/a", "o/b", "o/a", "o/b"]
  end

  # The test process pins its own workflow path (which wins by design), so
  # project-scoped reads run in a fresh process.
  defp in_fresh_process(fun), do: Task.async(fun) |> Task.await()

  test "snapshot is scoped to the project that took it", %{a: a, b: b} do
    in_fresh_process(fn ->
      Context.put(a)

      assert SettingsSnapshot.run(fn ->
               assert repo!() == "o/a"
               Context.put(b)
               repo!()
             end) == "o/b"
    end)
  end

  test "a project never reads the default store", %{a: a} do
    default = repo!()

    in_fresh_process(fn ->
      Context.put(a)
      assert repo!() == "o/a"
    end)

    refute default == "o/a"
  end

  test "the project's config path outranks the VM-global path", %{a: a} do
    assert Aiur.Workflow.workflow_file_path() != a.config_path

    in_fresh_process(fn ->
      Context.put(a)
      assert Aiur.Workflow.workflow_file_path() == a.config_path
      assert Context.without(&Aiur.Workflow.workflow_file_path/0) != a.config_path
    end)
  end

  test "cache rows are per project: B's publication does not turn A's row stale", %{a: a, b: b} do
    alias Aiur.WorkflowStore.Cache

    in_fresh_process(fn ->
      Context.put(a)
      Cache.put(%{who: :a}, 1, a.config_path)
      Context.put(b)
      Cache.put(%{who: :b}, 1, b.config_path)

      assert {:ok, %{who: :b}, 1, _} = Cache.fetch(b.config_path)
      Context.put(a)
      assert {:ok, %{who: :a}, 1, _} = Cache.fetch(a.config_path)
    end)
  end

  describe "machine-level files ignore the project context" do
    test "alerts directory", %{a: a} do
      File.write!(Path.join(Path.dirname(a.config_path), "alerts"), "alerts:\n  project_only:\n    message: Hi\n")
      machine = Aiur.Alerts.Config.definitions()

      in_fresh_process(fn ->
        Context.put(a)
        refute Map.has_key?(Aiur.Alerts.Config.definitions(), "project_only")
        assert Aiur.Alerts.Config.definitions() == machine
      end)
    end

    test "model-usage.json", %{a: a} do
      machine = Aiur.ModelAvailability.path()
      refute Path.dirname(machine) == Path.dirname(a.config_path)

      in_fresh_process(fn ->
        Context.put(a)
        assert Aiur.ModelAvailability.path() == machine
      end)
    end

    test "model-catalog.json", %{a: a} do
      machine = Aiur.ModelDiscovery.path()
      refute Path.dirname(machine) == Path.dirname(a.config_path)

      in_fresh_process(fn ->
        Context.put(a)
        assert Aiur.ModelDiscovery.path() == machine
      end)
    end
  end

  test "a nested snapshot for another project restores the outer one", %{a: a, b: b} do
    in_fresh_process(fn ->
      Context.put(a)

      SettingsSnapshot.run(fn ->
        Context.put(b)
        SettingsSnapshot.run(fn -> assert repo!() == "o/b" end)
        Context.put(a)
        # A's file changes on disk; A's snapshot must still answer, not a reload.
        write_workflow_file!(a.config_path, tracker_kind: "github", tracker_repo: "o/changed")
        assert SettingsSnapshot.read(fn -> :reloaded end) != :reloaded
      end)
    end)
  end
end
