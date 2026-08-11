defmodule Aiur.Scripts.GuardPRDeletionsTest do
  use ExUnit.Case, async: true

  @guard Path.expand("../../../scripts/guard-pr-deletions", __DIR__)
  @engine Path.expand("../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  test "fetches the remote base and refuses more than 50 untouched deletions" do
    repo = new_repo!()
    root = git!(repo, ["rev-parse", "HEAD"])

    develop = create_base_files!(repo, 51)
    git!(repo, ["checkout", "-q", "-b", "feature", root])
    git!(repo, ["update-ref", "refs/aiur/branch-start", root])
    write!(repo, "feature.txt", "feature\n")
    commit_all!(repo, "feature")
    git!(repo, ["update-ref", "refs/remotes/origin/develop", root])

    {output, status} = System.cmd(@guard, ["develop"], cd: repo, stderr_to_stdout: true)

    assert status == 1
    assert output =~ "refusing PR with 51 untouched file deletions"
    assert git!(repo, ["rev-parse", "FETCH_HEAD"]) == develop
  end

  test "allows exactly 50 untouched deletions through the packaged command" do
    repo = new_repo!()
    root = git!(repo, ["rev-parse", "HEAD"])

    create_base_files!(repo, 50)
    git!(repo, ["checkout", "-q", "-b", "feature", root])
    git!(repo, ["update-ref", "refs/aiur/branch-start", root])
    write!(repo, "feature.txt", "feature\n")
    commit_all!(repo, "feature")

    {output, status} = System.cmd(@engine, ["guard-pr-deletions", "develop"], cd: repo, stderr_to_stdout: true)

    assert status == 0
    assert output =~ "50 untouched file deletions"
  end

  test "allows deletions made by feature commits after the recorded branch start" do
    repo = new_repo!()
    develop = create_base_files!(repo, 51)

    git!(repo, ["checkout", "-q", "-b", "feature"])
    git!(repo, ["update-ref", "refs/aiur/branch-start", develop])

    for number <- 1..51 do
      File.rm!(Path.join(repo, "base-#{number}.txt"))
    end

    commit_all!(repo, "delete feature files")

    {output, status} = System.cmd(@guard, ["develop"], cd: repo, stderr_to_stdout: true)

    assert status == 0
    assert output =~ "0 untouched file deletions"
  end

  test "fails closed for bulk deletions without a recorded branch start" do
    repo = new_repo!()
    root = git!(repo, ["rev-parse", "HEAD"])

    create_base_files!(repo, 51)
    git!(repo, ["checkout", "-q", "-b", "feature", root])
    write!(repo, "feature.txt", "feature\n")
    commit_all!(repo, "feature")

    {output, status} = System.cmd(@guard, ["develop"], cd: repo, stderr_to_stdout: true)

    assert status == 1
    assert output =~ "branch-start ref is unavailable"
  end

  test "refuses to check a dirty tracked worktree" do
    repo = new_repo!()
    create_base_files!(repo, 1)
    write!(repo, "README.md", "pending deletion risk\n")

    {output, status} = System.cmd(@guard, ["develop"], cd: repo, stderr_to_stdout: true)

    assert status == 2
    assert output =~ "tracked changes must be committed"
  end

  defp new_repo! do
    root = Path.join(System.tmp_dir!(), "aiur-pr-deletion-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "work")
    origin = Path.join(root, "origin.git")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "seed"])
    git!(repo, ["config", "user.name", "Aiur Test"])
    git!(repo, ["config", "user.email", "aiur@example.test"])
    git!(root, ["init", "--bare", "-q", origin])
    git!(repo, ["remote", "add", "origin", origin])
    write!(repo, "README.md", "seed\n")
    commit_all!(repo, "seed")
    on_exit(fn -> File.rm_rf!(root) end)
    repo
  end

  defp create_base_files!(repo, count) do
    git!(repo, ["checkout", "-q", "-b", "develop"])

    for number <- 1..count do
      write!(repo, "base-#{number}.txt", "base\n")
    end

    commit_all!(repo, "add base files")
    git!(repo, ["push", "-q", "origin", "develop"])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp write!(repo, path, contents) do
    File.write!(Path.join(repo, path), contents)
  end

  defp commit_all!(repo, message) do
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", message])
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end
end
