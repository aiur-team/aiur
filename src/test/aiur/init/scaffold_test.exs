defmodule Aiur.Init.ScaffoldTest do
  use ExUnit.Case, async: false

  alias Aiur.Init.Scaffold

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-scaffold-test-#{System.unique_integer([:positive])}")
    target = Path.join([dir, ".aiur", "config"])
    File.mkdir_p!(Path.dirname(target))
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, target: target}
  end

  test "sibling writers create once and never clobber", %{target: target} do
    assert {:created, prompt} = Scaffold.write_prompt_file(target, "prompt.md", "owner/repo")
    File.write!(prompt, "custom prompt")
    assert {:exists, ^prompt} = Scaffold.write_prompt_file(target, "prompt.md", "owner/repo")
    assert File.read!(prompt) == "custom prompt"

    assert {:created, hooks} = Scaffold.write_aiurhooks(target)
    File.write!(hooks, "custom hooks")
    assert {:exists, ^hooks} = Scaffold.write_aiurhooks(target)
    assert File.read!(hooks) == "custom hooks"

    assert {:created, prewarm} = Scaffold.write_prewarm_file(target, "mise exec -- mix compile")
    File.write!(prewarm, "custom prewarm")
    assert {:exists, ^prewarm} = Scaffold.write_prewarm_file(target, "mise exec -- mix compile")
    assert File.read!(prewarm) == "custom prewarm"
  end

  test "generated hooks use the exported configured base branch", %{target: target} do
    assert {:created, hooks} = Scaffold.write_aiurhooks(target)

    contents = File.read!(hooks)
    assert contents =~ "THIS_BASE_BRANCH"
    assert contents =~ "AIUR_TICKET_BRANCH"
    refute contents =~ "origin/main"
  end

  test "ensure_env rewrites example but never clobbers env", %{dir: dir} do
    File.cd!(dir, fn ->
      assert {:created, env} = Scaffold.ensure_env("GITHUB_TOKEN=one\n")
      File.write!(env, "GITHUB_TOKEN=custom\n")

      assert {:exists, ^env} = Scaffold.ensure_env("GITHUB_TOKEN=two\n")
      assert File.read!(env) == "GITHUB_TOKEN=custom\n"
      assert File.read!(Path.join(dir, ".env.example")) == "GITHUB_TOKEN=two\n"
    end)
  end

  test "append_config_section appends after blank line", %{target: target} do
    File.write!(target, "tracker:\n  kind: github\n")

    assert {:ok, ^target} = Scaffold.append_config_section(target, ["prewarm:\n", "  enabled: true\n"])
    assert File.read!(target) == "tracker:\n  kind: github\n\nprewarm:\n  enabled: true\n"
  end

  test "add_gitignore_entry is idempotent and preserves missing trailing newline", %{dir: dir} do
    gitignore = Path.join(dir, ".gitignore")
    File.write!(gitignore, ".env")

    assert {:added, ^gitignore} = Scaffold.add_gitignore_entry(dir, ".aiur/")
    assert File.read!(gitignore) == ".env\n.aiur/\n"
    assert {:exists, ^gitignore} = Scaffold.add_gitignore_entry(dir, ".aiur/")
    assert File.read!(gitignore) == ".env\n.aiur/\n"
  end
end
