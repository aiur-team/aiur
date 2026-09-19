defmodule Aiur.TestBootGuardTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths
  alias Aiur.GitHub.Budget

  test "test budget writes land under the per-VM temporary root" do
    root = Application.fetch_env!(:aiur, :test_state_root)
    assert {:ok, _} = Aiur.PathSafety.contained?(System.tmp_dir!(), root)
    assert Budget.state_dir() == Path.join(root, "github-budget")
    assert Aiur.AgentGitHubGuard.agent_token_path() == Path.join(root, "github-budget/agent-token")
  end

  test "runtime state requires an explicit override inside the per-VM root" do
    root = Application.fetch_env!(:aiur, :test_state_root)
    original = Application.fetch_env!(:aiur, :runtime_state_dir)
    assert {:ok, runtime} = Paths.runtime_state_dir()
    assert runtime == Path.join(root, "runtime-state")

    try do
      Application.delete_env(:aiur, :runtime_state_dir)

      assert_raise RuntimeError, ~r/TEST BOOT ISOLATION: unsafe runtime_state_dir/, fn ->
        Aiur.TestBootGuard.check!()
      end

      Application.put_env(:aiur, :runtime_state_dir, Path.join(root, "../escaped-runtime"))

      assert_raise RuntimeError, ~r/TEST BOOT ISOLATION: unsafe runtime_state_dir/, fn ->
        Aiur.TestBootGuard.check!()
      end
    after
      Application.put_env(:aiur, :runtime_state_dir, original)
    end
  end

  test "host guard installation and legacy cleanup stay in the configured host directory" do
    bin = Aiur.AgentGitHubGuard.host_bin_dir()
    root = Application.fetch_env!(:aiur, :test_state_root)
    assert {:ok, _} = Aiur.PathSafety.contained?(root, bin)
    legacy = Path.join([Path.dirname(bin), "github-budget/bin/gh"])
    File.mkdir_p!(Path.dirname(legacy))
    File.write!(legacy, "Fleet guard for agent-launched `gh` calls.")

    try do
      assert :ok = Aiur.AgentGitHubGuard.install_host()
      assert File.read!(Path.join(bin, "gh")) =~ "Fleet guard"
      refute File.exists?(legacy)
    after
      File.rm_rf!(Path.dirname(bin))
    end
  end

  test "boot guard rejects original HOME state including normalized paths" do
    home = Path.join(System.tmp_dir!(), "fake-original-home")

    for path <- [".aiur", ".aiur/github-budget", ".config/aiur/runtime", ".aiur/other/../github-budget"] do
      assert_raise RuntimeError, ~r/TEST BOOT ISOLATION: unsafe budget/, fn ->
        Aiur.TestBootGuard.assert_safe!([budget: Path.join(home, path)], home)
      end
    end

    assert :ok = Aiur.TestBootGuard.assert_safe!([budget: Path.join(home, ".aiur-other")], home)
  end
end
