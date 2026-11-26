defmodule Aiur.TestGitTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  test "a fixture commit ignores configured hooks and signing", %{tmp_dir: root} do
    hooks = Path.join(root, "hooks")
    File.mkdir_p!(hooks)
    File.write!(Path.join(hooks, "pre-commit"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(hooks, "pre-commit"), 0o755)

    git = fn args -> Aiur.TestGit.cmd(["-C", root, "-c", "user.name=t", "-c", "user.email=t@t" | args]) end
    {_, 0} = git.(["init", "--quiet"])
    {_, 0} = git.(["config", "core.hooksPath", hooks])
    {_, 0} = git.(["config", "commit.gpgsign", "true"])

    assert {_, 0} = git.(["commit", "--quiet", "--allow-empty", "-m", "fixture"])
  end
end
