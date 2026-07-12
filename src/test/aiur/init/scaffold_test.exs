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

  test "ensure_env creates a missing env with only the GitHub token line", %{dir: dir} do
    File.cd!(dir, fn ->
      assert {:created, env} = Scaffold.ensure_env("GITHUB_TOKEN=\n")
      assert File.read!(env) == "GITHUB_TOKEN=\n"
    end)
  end

  test "ensure_env appends the GitHub token without rewriting existing content", %{dir: dir} do
    File.cd!(dir, fn ->
      env = Path.join(dir, ".env")

      for {existing, expected} <- [
            {"", "GITHUB_TOKEN=\n"},
            {"OTHER=value", "OTHER=value\nGITHUB_TOKEN=\n"},
            {"OTHER=value\n", "OTHER=value\nGITHUB_TOKEN=\n"}
          ] do
        File.write!(env, existing)

        assert {:exists, ^env} = Scaffold.ensure_env("GITHUB_TOKEN=\n")
        assert File.read!(env) == expected
      end
    end)
  end

  test "ensure_env leaves an existing GitHub token entry byte-for-byte unchanged", %{dir: dir} do
    File.cd!(dir, fn ->
      env = Path.join(dir, ".env")
      original = "OTHER=value\nGITHUB_TOKEN="
      File.write!(env, original)

      assert {:exists, ^env} = Scaffold.ensure_env("GITHUB_TOKEN=\n")
      assert File.read!(env) == original
    end)
  end

  test "ensure_env never creates or modifies env example", %{dir: dir} do
    File.cd!(dir, fn ->
      example = Path.join(dir, ".env.example")

      assert {:created, _env} = Scaffold.ensure_env("GITHUB_TOKEN=\n")
      refute File.exists?(example)

      File.write!(example, "project-owned example\n")
      assert {:exists, _env} = Scaffold.ensure_env("GITHUB_TOKEN=\n")
      assert File.read!(example) == "project-owned example\n"
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
