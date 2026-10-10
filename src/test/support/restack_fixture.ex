defmodule Aiur.TestSupport.RestackFixture do
  @moduledoc false
  alias Aiur.TestSupport
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  @spec create() :: map()
  def create do
    root = TestSupport.tmp_root!("restack")
    origin = Path.join(root, "origin.git")
    workspace = Path.join([root, "owner", "repo", "20"])
    File.mkdir_p!(workspace)
    git(root, ["init", "--bare", origin])
    git(workspace, ["init", "-b", "main"])
    git(workspace, ["config", "user.name", "Restack test"])
    git(workspace, ["config", "user.email", "test@example.invalid"])
    git(workspace, ["remote", "add", "origin", origin])
    File.write!(Path.join(workspace, "base"), "base\n")
    commit(workspace, "base")
    git(workspace, ["push", "origin", "main"])
    dependent = dependent(workspace)
    merge = squash(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, origin: origin, dependent: dependent, merge: merge}
  end

  defp dependent(workspace) do
    git(workspace, ["checkout", "-b", "blocker"])
    File.write!(Path.join(workspace, "shared"), "blocker\n")
    File.write!(Path.join(workspace, "blocker-only"), "unchanged\n")
    commit(workspace, "blocker")
    git(workspace, ["push", "origin", "HEAD:refs/pull/42/head"])
    git(workspace, ["checkout", "-b", "dependent"])
    File.write!(Path.join(workspace, "shared"), "dependent\n")
    commit(workspace, "dependent")
    sha = git(workspace, ["rev-parse", "HEAD"])
    git(workspace, ["push", "origin", "dependent"])
    sha
  end

  defp squash(workspace) do
    git(workspace, ["checkout", "main"])
    git(workspace, ["merge", "--squash", "blocker"])
    commit(workspace, "squash")
    merge = git(workspace, ["rev-parse", "HEAD"])
    git(workspace, ["push", "origin", "main"])
    git(workspace, ["checkout", "dependent"])
    merge
  end

  defp commit(path, message) do
    git(path, ["add", "."])
    git(path, ["commit", "-m", message])
  end

  @spec command(Path.t(), [String.t()]) :: {String.t(), integer()}
  def command(path, args), do: System.cmd(System.get_env("AIUR_REAL_GIT") || System.find_executable("git"), ["-C", path | args], stderr_to_stdout: true)

  @spec git(Path.t(), [String.t()]) :: String.t()
  def git(path, args) do
    {output, status} = command(path, args)
    assert status == 0, output
    String.trim(output)
  end
end
