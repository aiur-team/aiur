defmodule Aiur.Experiments.Auto.TagReaderTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Auto.TagReader

  test "remote refs and annotated and lightweight dates come from real git" do
    root = Path.join(System.tmp_dir!(), "release-tags-#{System.unique_integer([:positive])}")
    remote = Path.join(root, "remote")
    clone = Path.join(root, "clone")
    File.mkdir_p!(remote)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    git = fn repo, args, env ->
      assert {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true, env: env)
      output
    end

    git.(remote, ["init"], [])

    env = [
      {"GIT_AUTHOR_NAME", "Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"},
      {"GIT_AUTHOR_DATE", "2026-10-01T00:00:00Z"},
      {"GIT_COMMITTER_DATE", "2026-10-01T00:00:00Z"}
    ]

    git.(remote, ["commit", "--allow-empty", "-m", "Initial"], env)
    git.(remote, ["tag", "v1.0.0"], env)
    git.(remote, ["tag", "-a", "v1.1.0", "-m", "Release"], List.keyreplace(env, "GIT_COMMITTER_DATE", 0, {"GIT_COMMITTER_DATE", "2026-10-02T00:00:00Z"}))
    git.(root, ["clone", "--no-tags", remote, clone], [])
    assert {:ok, tags} = TagReader.list(clone)
    assert Enum.sort(tags) == ["v1.0.0", "v1.1.0"]
    assert {:ok, ~U[2026-10-01 00:00:00Z]} = TagReader.date(clone, "v1.0.0")
    assert {:ok, ~U[2026-10-02 00:00:00Z]} = TagReader.date(clone, "v1.1.0")
    git.(clone, ["remote", "set-url", "origin", Path.join(root, "missing")], [])
    assert {:error, {:git_failed, 128}} = TagReader.list(clone)
  end
end
