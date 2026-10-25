defmodule Aiur.Config.StateRootTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths
  alias Aiur.GitHub.Budget
  alias Aiur.TestCleanup

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-state-root-#{System.unique_integer([:positive])}")
    on_exit(fn -> TestCleanup.rm_rf!(root) end)

    %{root: Path.join(root, "volume")}
  end

  test "budget and instance secret stores both use the mounted root", %{root: root} do
    key = {Paths, :state_root_override}
    previous = Process.get(key)
    previous_secret_root = Application.get_env(:aiur, :dashboard_secret_root)
    previous_budget_dir = Application.get_env(:aiur, :github_budget_dir)
    Process.put(key, root)
    Application.put_env(:aiur, :dashboard_secret_root, root)
    Application.delete_env(:aiur, :github_budget_dir)

    try do
      # Check destinations before writing so a broken resolver cannot touch
      # the operator's home directory.
      assert Paths.dashboard_secret_root() == root
      assert Budget.state_dir() == Path.join(root, "github-budget")
      assert :ok = Budget.ensure_state_dir()
      assert is_binary(Aiur.HttpServer.secret_key_base_for_test())

      assert File.regular?(Path.join([root, "instances", "default", "secret_key_base"]))
    after
      if is_nil(previous), do: Process.delete(key), else: Process.put(key, previous)
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
end
