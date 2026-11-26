defmodule Aiur.Machine.SettingsProjectsTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [refute_leak: 2]
  alias Aiur.Machine.Settings

  setup do
    home = Path.join(System.tmp_dir!(), "machine-projects-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, ".aiur"))
    path = Path.join(home, ".aiur/machine")
    previous = Application.get_env(:aiur, :machine_settings_path)
    Application.put_env(:aiur, :machine_settings_path, path)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :machine_settings_path, previous), else: Application.delete_env(:aiur, :machine_settings_path)
      :persistent_term.erase({Settings, path})
      Aiur.TestCleanup.rm_rf!(home)
    end)

    %{path: path}
  end

  defp load(path, yaml) do
    File.write!(path, yaml)
    Settings.load()
  end

  defp invalid(path, yaml) do
    assert {:error, {:invalid, errors}} = load(path, yaml)
    errors
  end

  test "defaults when sections are absent", %{path: path} do
    assert {:ok, s} = load(path, "")
    assert s.projects == []
    assert s.capacity.max_agents == nil
    assert {s.coordination.database_url_env, s.coordination.offline_after_seconds} == {"AIUR_LEASE_DATABASE_URL", 180}
  end

  test "projects, capacity and coordination load with their values", %{path: path} do
    assert {:ok, s} =
             load(path, """
             projects:
               - {repo: o/r, config: /abs/.aiur/config, max_agents: 4}
               - {repo: o/two, config: "~/x/.aiur/config", priority: 1}
             capacity: {max_agents: 12}
             coordination: {database_url_env: MY_DB, offline_after_seconds: 30}
             """)

    assert [%{repo: "o/r", config: "/abs/.aiur/config", max_agents: 4, priority: nil}, %{repo: "o/two", priority: 1} = two] = s.projects
    assert two.config == Path.expand("~/x/.aiur/config")
    assert s.capacity.max_agents == 12
    assert {s.coordination.database_url_env, s.coordination.offline_after_seconds} == {"MY_DB", 30}
  end

  test "invalid values name the key and never echo the config path", %{path: path} do
    errors =
      invalid(path, """
      projects:
        - {repo: justname, config: /abs/secret-checkout/config}
        - {repo: o/r, config: rel/secret-checkout/config, max_agents: 0, priority: -1}
      capacity: {max_agents: 0}
      coordination: {database_url_env: "postgres://u:pw@h/db", offline_after_seconds: 29}
      """)

    keys = Enum.map(errors, &elem(&1, 0))

    for key <- ~w(projects[0].repo projects[1].config projects[1].max_agents projects[1].priority capacity.max_agents coordination.database_url_env coordination.offline_after_seconds) do
      assert key in keys
    end

    assert {"projects[0].repo", "must be owner/name"} in errors
    assert {"projects[1].config", "must be an absolute path"} in errors
    refute_leak(errors, "secret-checkout")
    refute_leak(errors, "pw@h")
  end

  test "unknown keys inside list entries and sections are rejected", %{path: path} do
    errors =
      invalid(path, """
      projects: [{repo: o/r, config: /a, repo_name: x}]
      capacity: {max: 3}
      coordination: {foo: 1}
      """)

    assert {"projects[0].repo_name", "unknown key"} in errors
    assert {"capacity.max", "unknown key"} in errors
    assert {"coordination.foo", "unknown key"} in errors
  end

  test "duplicate repos (case-insensitive) and duplicate configs are rejected", %{path: path} do
    assert {"projects", "a repo is listed more than once"} in invalid(path, "projects: [{repo: o/r, config: /a}, {repo: O/R, config: /b}]")
    errors = invalid(path, "projects: [{repo: o/r, config: /dup-path}, {repo: o/s, config: /dup-path}]")
    assert {"projects", "a config path is listed more than once"} in errors
    refute_leak(errors, "dup-path")
  end

  test "a project above the machine cap is accepted", %{path: path} do
    assert {:ok, _} = load(path, "capacity: {max_agents: 4}\nprojects: [{repo: o/r, config: /a, max_agents: 8}]")
  end

  test "inspect omits the config path", %{path: path} do
    assert {:ok, s} = load(path, "projects: [{repo: o/r, config: /private-checkout/config}]")
    refute_leak(s.projects, "private-checkout")
  end

  test "a project without config, blank repo/config and ~user paths are rejected", %{path: path} do
    errors = invalid(path, "projects: [{repo: o/r}]")
    assert {"projects[0].config", "can't be blank"} in errors

    errors = invalid(path, "projects: [{repo: \"\", config: \"\"}]")
    assert {"projects[0].repo", "must be owner/name"} in errors
    assert {"projects[0].config", "must be an absolute path"} in errors

    assert {"projects[0].config", "must be an absolute path"} in invalid(path, "projects: [{repo: o/r, config: \"~bob/x\"}]")
  end

  test "projects must be a list", %{path: path} do
    assert {"projects", "is invalid"} in invalid(path, "projects: {repo: o/r}")
  end

  test "offline_after_seconds accepts 30 and 86400 and rejects 86401", %{path: path} do
    assert {:ok, _} = load(path, "coordination: {offline_after_seconds: 30}")
    assert {:ok, _} = load(path, "coordination: {offline_after_seconds: 86400}")
    assert [{"coordination.offline_after_seconds", _}] = invalid(path, "coordination: {offline_after_seconds: 86401}")
  end

  test "write replaces the whole project list and keeps mode 0600", %{path: path} do
    assert :ok = Settings.write(%{"projects" => [%{"repo" => "o/a", "config" => "/a"}, %{"repo" => "o/b", "config" => "/b"}]})
    assert {:ok, %{projects: [%{repo: "o/a"}, %{repo: "o/b"}]}} = Settings.load()
    assert :ok = Settings.write(%{"projects" => [%{"repo" => "o/c", "config" => "/c"}]})
    assert {:ok, %{projects: [%{repo: "o/c", config: "/c"}]}} = Settings.load()
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end
end
