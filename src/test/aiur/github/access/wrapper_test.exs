defmodule Aiur.GitHub.Access.WrapperTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  alias Aiur.AgentGitHubGuard
  alias Aiur.AgentGitHubGuard.Script
  alias Aiur.GitHub.HostCommand
  alias Aiur.GitHub.Access.{Wrapper, WrapperRecursion, WrapperSource}

  @hash_path Path.expand("../../../../priv/github_guard/aiur-gh.sha256", __DIR__)

  test "Aiur composition preserves the pre-extraction hash" do
    assert Base.encode16(:crypto.hash(:sha256, WrapperSource.aiur()), case: :lower) == String.trim(File.read!(@hash_path))
    assert WrapperSource.paths() == Script.paths()[:gh]
  end

  # Characterization guard: these bytes and modes must remain unchanged by extraction.
  test "workspace placement installs the embedded Aiur artifacts at the original modes", %{tmp_dir: tmp_dir} do
    assert :ok = AgentGitHubGuard.install(tmp_dir)
    bin = AgentGitHubGuard.bin_dir(tmp_dir)
    assert Enum.sort(File.ls!(bin)) == ~w(aiur-github-budget gh git github_budget_metrics.py)

    for {name, bytes} <- Wrapper.scripts() do
      assert File.read!(Path.join(bin, name)) == bytes
      assert Bitwise.band(File.stat!(Path.join(bin, name)).mode, 0o777) == 0o755
    end

    assert File.read!(Path.join(bin, "gh")) == WrapperRecursion.splice(WrapperSource.aiur(), "gh")
    assert Wrapper.budget_broker_path(tmp_dir) == Path.join(bin, "aiur-github-budget")
    assert File.dir?(AgentGitHubGuard.gh_config_dir(tmp_dir))
    assert File.dir?(AgentGitHubGuard.quota_dir(tmp_dir))
    assert AgentGitHubGuard.missing_workspace_support(tmp_dir) == []
  end

  test "host install and credential mechanics are available through GitHub Access", %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:aiur, :host_guard_bin_dir)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :host_guard_bin_dir, previous), else: Application.delete_env(:aiur, :host_guard_bin_dir)
    end)

    bin = Path.join(tmp_dir, "bin")
    Application.put_env(:aiur, :host_guard_bin_dir, bin)
    assert Wrapper.host_bin_dir() == bin
    assert Wrapper.install_host() == :ok
    assert Enum.sort(File.ls!(bin)) == ~w(aiur-github-budget gh github_budget_metrics.py)
    assert Wrapper.agent_token_path() == AgentGitHubGuard.agent_token_path()

    token = Path.join(tmp_dir, "credential")
    assert Wrapper.ensure_agent_token_file(path: token, token: "test-credential") == :ok
    assert File.read!(token) == "test-credential\n"
    assert Bitwise.band(File.stat!(token).mode, 0o777) == 0o600
    assert Wrapper.ensure_agent_token_file(path: token, token: :none) == :no_credential
    refute File.exists?(token)
  end

  # Future regression guard: resolving the existing location must survive the boundary refactor.
  test "installer and host commands resolve the same configured wrapper", %{tmp_dir: root} do
    previous = Application.fetch_env(:aiur, :host_guard_bin_dir)
    on_exit(fn -> Aiur.TestSupport.restore_app_env([{:host_guard_bin_dir, previous}]) end)
    Application.put_env(:aiur, :host_guard_bin_dir, root)
    executable = Path.join(root, "gh")
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    File.chmod!(executable, 0o755)

    assert Aiur.AgentGitHubGuard.host_bin_dir() == root
    assert HostCommand.find_executable() == executable
  end
end
