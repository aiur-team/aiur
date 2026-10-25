defmodule Aiur.Config.StateRootTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths
  alias Aiur.GitHub.Budget
  alias Aiur.TestCleanup

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-state-root-#{System.unique_integer([:positive])}")
    on_exit(fn -> TestCleanup.rm_rf!(root) end)

    home = Path.join(root, "home")
    File.mkdir_p!(home)
    %{root: Path.join(root, "volume"), home: home}
  end

  test "budget and instance secret stores both use the mounted root", %{root: root, home: home} do
    previous_home = System.get_env("HOME")
    previous_state_dir = System.get_env("AIUR_STATE_DIR")
    previous_budget_dir = Application.get_env(:aiur, :github_budget_dir)
    previous_secret_root = Application.get_env(:aiur, :dashboard_secret_root)
    System.put_env("HOME", home)
    System.put_env("AIUR_STATE_DIR", root)
    Application.delete_env(:aiur, :dashboard_secret_root)
    Application.delete_env(:aiur, :github_budget_dir)

    try do
      assert Paths.state_root() == root
      assert Paths.dashboard_secret_root() == root
      assert Budget.state_dir() == Path.join(root, "github-budget")
      assert :ok = Budget.ensure_state_dir()
      assert is_binary(Aiur.HttpServer.secret_key_base_for_test())

      assert File.regular?(Path.join([root, "instances", "default", "secret_key_base"]))
      refute File.exists?(Path.join(home, ".aiur"))
    after
      restore_system_env("HOME", previous_home)
      restore_system_env("AIUR_STATE_DIR", previous_state_dir)
      restore_env(:dashboard_secret_root, previous_secret_root)
      restore_env(:github_budget_dir, previous_budget_dir)
    end
  end

  test "AIUR_STATE_DIR overrides the default ~/.aiur root" do
    root = Path.join(System.tmp_dir!(), "aiur-state-env-#{System.unique_integer([:positive])}")
    assert Paths.state_root(%{"AIUR_STATE_DIR" => root}) == root
    assert Paths.state_root(%{}) == Path.join(System.user_home!(), ".aiur")
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
