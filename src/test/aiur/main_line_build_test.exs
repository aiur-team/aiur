defmodule Aiur.MainLineBuildTest do
  use ExUnit.Case, async: true

  alias Aiur.MainLineBuild
  alias Aiur.Project.StatusRows

  test "reports a stamped commit on tracked main" do
    repo = git_repo()
    sha = commit(repo, "main")
    git(repo, ["branch", "-M", "main"])
    git(repo, ["update-ref", "refs/remotes/origin/main", sha])

    assert %{status: :on_main, commit: ^sha, commits_ahead: 0} = MainLineBuild.current(stamp: stamp(repo, sha))
    assert MainLineBuild.line(%{status: :on_main, commit: sha}) == "build: #{sha} (on main)"
  end

  test "reports commits outside tracked main" do
    repo = git_repo()
    main_sha = commit(repo, "main")
    git(repo, ["branch", "-M", "main"])
    git(repo, ["update-ref", "refs/remotes/origin/main", main_sha])
    File.write!(Path.join(repo, "file"), "pin")
    git(repo, ["add", "file"])
    tree = git(repo, ["write-tree"]) |> String.trim()
    pin_sha = git(repo, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree, "-p", main_sha, "-m", "pin"]) |> String.trim()

    assert %{status: :not_on_main, commit: ^pin_sha, commits_ahead: 1} = MainLineBuild.current(stamp: stamp(repo, pin_sha))
    assert MainLineBuild.line(%{status: :not_on_main, commit: pin_sha, commits_ahead: 1}) == "build: #{pin_sha} NOT ON MAIN (1 commits ahead)"
  end

  test "keeps unavailable main state explicitly unknown" do
    repo = git_repo()
    sha = commit(repo, "main")
    result = MainLineBuild.current(stamp: stamp(repo, sha), git: fn _git, _args, _opts -> {"", 128} end)

    assert %{status: :unknown, commit: ^sha, commits_ahead: nil} = result
    assert MainLineBuild.line(result) == "build: #{sha} (unknown)"
  end

  test "announces an off-main build with a warning and attention" do
    sha = String.duplicate("a", 40)
    result = %{status: :not_on_main, commit: sha, commits_ahead: 3}
    test_pid = self()

    assert :ok =
             MainLineBuild.announce(
               current: fn -> result end,
               warn: fn message -> send(test_pid, {:warning, message}) end,
               alert: fn topic, opts -> send(test_pid, {:alert, topic, opts}) end
             )

    warning = "Running build #{sha} is not on main (3 commits ahead)."
    assert_receive {:warning, ^warning}, 100
    assert_receive {:alert, "system.build.not_on_main", opts}, 100
    assert opts[:needs_attention]
  end

  test "does not announce an on-main build" do
    test_pid = self()
    assert :ok = MainLineBuild.announce(current: fn -> %{status: :on_main} end, warn: fn _ -> send(test_pid, :warning) end, alert: fn _, _ -> send(test_pid, :alert) end)
    refute_received :warning
    refute_received :alert
  end

  test "status JSON exposes the build state field" do
    assert %{build: %{status: status, commits_ahead: ahead}} = StatusRows.json()
    assert status in [:on_main, :not_on_main, :unknown]
    assert is_integer(ahead) or is_nil(ahead)
  end

  defp git_repo do
    path = Path.join(System.tmp_dir!(), "main-line-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    git(path, ["init", "-q"])
    git(path, ["config", "user.email", "test@example.invalid"])
    git(path, ["config", "user.name", "Test"])
    path
  end

  defp commit(repo, content) do
    File.write!(Path.join(repo, "file"), content)
    git(repo, ["add", "file"])
    git(repo, ["commit", "-qm", content])
    git(repo, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    output
  end

  defp stamp(repo, sha), do: %{"repo_root" => repo, "source_sha" => sha}
end
