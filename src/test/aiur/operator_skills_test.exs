defmodule Aiur.OperatorSkillsTest do
  use ExUnit.Case, async: true

  alias Aiur.OperatorSkills

  @source_root Path.expand("../../../.claude/skills", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-operator-skills-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, home: home}
  end

  test "symlinks every operator skill into detected harness roots and is idempotent", %{home: home, root: root} do
    assert {:ok, %{created: created, existing: []}} =
             OperatorSkills.install(:symlink, [:claude, :codex], home: home, source_root: @source_root)

    assert length(created) == map_size(OperatorSkills.skills()) * 2

    consumer_repo = Path.join(root, "consumer-repo")
    File.mkdir_p!(consumer_repo)

    for {source_name, installed_name} <- OperatorSkills.skills(), harness <- [".claude", ".codex"] do
      skill = Path.join([home, harness, "skills", installed_name])
      assert {:ok, target} = File.read_link(skill)
      assert Path.expand(target, Path.dirname(skill)) == Path.join(@source_root, source_name)
      assert File.read!(Path.join(skill, "SKILL.md")) =~ "name:"
    end

    assert {:ok, %{created: [], existing: existing}} =
             OperatorSkills.install(:symlink, [:claude, :codex], home: home, source_root: @source_root)

    assert length(existing) == map_size(OperatorSkills.skills()) * 2
  end

  test "copy mode creates pinned directories", %{home: home} do
    assert {:ok, %{created: created}} = OperatorSkills.install(:copy, [:claude], home: home, source_root: @source_root)
    assert length(created) == map_size(OperatorSkills.skills())

    for installed_name <- Map.values(OperatorSkills.skills()) do
      destination = Path.join([home, ".claude", "skills", installed_name])
      refute match?({:ok, _}, File.read_link(destination))
      assert File.regular?(Path.join(destination, "SKILL.md"))
    end
  end

  test "leaves unrelated skill directories untouched", %{home: home} do
    destination = Path.join([home, ".claude", "skills", "aiur-run"])
    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "SKILL.md"), "unrelated")

    assert {:conflict, conflicts} = OperatorSkills.install(:symlink, [:claude], home: home, source_root: @source_root)
    assert destination in conflicts
    assert File.read!(Path.join(destination, "SKILL.md")) == "unrelated"
  end

  test "only repoints an explicitly approved different link", %{home: home, root: root} do
    destination = Path.join([home, ".claude", "skills", "aiur-run"])
    other_source = Path.join(root, "other-aiur-run")
    File.mkdir_p!(other_source)
    File.mkdir_p!(Path.dirname(destination))
    File.ln_s!(other_source, destination)

    assert {:conflict, _} = OperatorSkills.install(:symlink, [:claude], home: home, source_root: @source_root)

    assert {:ok, _} =
             OperatorSkills.install(:symlink, [:claude], home: home, source_root: @source_root, replace_links?: true)

    assert {:ok, target} = File.read_link(destination)
    assert Path.expand(target, Path.dirname(destination)) == Path.join(@source_root, "aiur-run")
  end

  test "detects only present harnesses", %{home: home} do
    File.mkdir_p!(Path.join(home, ".codex/skills"))

    assert OperatorSkills.detect_harnesses(home: home, executable?: fn _ -> nil end) == [:codex]
    assert OperatorSkills.detect_harnesses(home: home, executable?: fn executable -> if executable == "claude", do: "/bin/claude" end) == [:claude, :codex]
  end
end
