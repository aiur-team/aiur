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

  test "copy mode recognises only its own earlier install as kept", %{home: home} do
    assert {:ok, first} = OperatorSkills.install(:copy, [:claude], home: home, source_root: @source_root)
    assert length(first.created) == map_size(OperatorSkills.skills())

    # Provenance is written down, because a copy has no link target to prove it.
    for %{destination: destination, skill: skill} <- first.created do
      assert File.read!(Path.join(destination, OperatorSkills.marker_filename())) |> String.trim() == skill
    end

    assert {:ok, second} = OperatorSkills.install(:copy, [:claude], home: home, source_root: @source_root)
    assert second.created == []
    assert second.skipped == []
    assert length(second.existing) == map_size(OperatorSkills.skills())
  end

  test "copy mode skips an unrelated directory instead of counting it as kept", %{home: home} do
    destination = Path.join([home, ".claude", "skills", "aiur-run"])
    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "SKILL.md"), "the operator's own skill")

    assert {:ok, report} = OperatorSkills.install(:copy, [:claude], home: home, source_root: @source_root)

    # Never counted as a kept operator skill -- it was never ours.
    assert report.existing == []
    assert [%{destination: ^destination, reason: :occupied, skill: "aiur-run"}] = report.skipped

    # And the rest still install, leaving the operator's directory alone.
    assert length(report.created) == map_size(OperatorSkills.skills()) - 1
    assert File.read!(Path.join(destination, "SKILL.md")) == "the operator's own skill"
    refute File.exists?(Path.join(destination, OperatorSkills.marker_filename()))
  end

  test "one blocked destination does not abort the other skills", %{home: home} do
    destination = Path.join([home, ".claude", "skills", "aiur-run"])
    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "SKILL.md"), "unrelated")

    assert {:ok, report} = OperatorSkills.install(:symlink, [:claude], home: home, source_root: @source_root)

    # The plain user directory is skipped, and named, with the reason that is
    # actually true of it: something occupies the path, it is not a stale link.
    assert [%{destination: ^destination, reason: :occupied, skill: "aiur-run"}] = report.skipped
    assert File.read!(Path.join(destination, "SKILL.md")) == "unrelated"

    # Every other skill still installs.
    assert length(report.created) == map_size(OperatorSkills.skills()) - 1
    refute Enum.any?(report.created, &(&1.skill == "aiur-run"))

    for %{destination: created} <- report.created do
      assert {:ok, _target} = File.read_link(created)
    end
  end

  test "a stale link is reported as a link, not as an occupied path", %{home: home, root: root} do
    destination = Path.join([home, ".claude", "skills", "aiur-run"])
    other_source = Path.join(root, "other-aiur-run")
    File.mkdir_p!(other_source)
    File.mkdir_p!(Path.dirname(destination))
    File.ln_s!(other_source, destination)

    assert {:ok, report} = OperatorSkills.install(:symlink, [:claude], home: home, source_root: @source_root)
    assert [%{destination: ^destination, reason: :link_elsewhere}] = report.skipped
    assert length(report.created) == map_size(OperatorSkills.skills()) - 1

    assert {:ok, repointed} =
             OperatorSkills.install(:symlink, [:claude], home: home, source_root: @source_root, replace_links?: true)

    assert repointed.skipped == []
    assert [%{destination: ^destination}] = repointed.created

    assert {:ok, target} = File.read_link(destination)
    assert Path.expand(target, Path.dirname(destination)) == Path.join(@source_root, "aiur-run")
  end

  test "reports what it managed to write when a later destination fails", %{home: home} do
    # A read-only skills root: every claude destination fails to be written,
    # while codex was already written to disk before the first failure.
    claude_skills = Path.join([home, ".claude", "skills"])
    File.mkdir_p!(claude_skills)
    File.chmod!(claude_skills, 0o500)
    on_exit(fn -> File.chmod(claude_skills, 0o700) end)

    assert {:ok, report} = OperatorSkills.install(:symlink, [:codex, :claude], home: home, source_root: @source_root)

    assert length(report.created) == map_size(OperatorSkills.skills())
    assert length(report.failed) == map_size(OperatorSkills.skills())
    assert Enum.all?(report.created, &(&1.harness == :codex))
    assert Enum.all?(report.failed, &(&1.harness == :claude))

    # The created entries are not a claim -- the symlinks are really there.
    for %{destination: created} <- report.created do
      assert {:ok, _target} = File.read_link(created)
    end

    assert Enum.all?(report.failed, &match?(%{reason: {_posix, _path}}, &1))
  end

  test "bundles every skill the shipped operating manual points at", %{home: home} do
    manual = File.read!(Path.join(@source_root, "aiur-run/SKILL.md"))

    referenced =
      ~r{`/(aiur-[a-z-]+)`}
      |> Regex.scan(manual)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()
      |> Enum.filter(&File.dir?(Path.join(@source_root, &1)))

    assert referenced != [], "expected the manual to reference at least one sibling skill"

    assert {:ok, report} = OperatorSkills.install(:symlink, [:claude], home: home, source_root: @source_root)
    installed = MapSet.new(report.created, & &1.skill)

    for skill <- referenced do
      assert MapSet.member?(installed, skill),
             "the operating manual tells the operator to run /#{skill}, but the install does not ship it"
    end
  end

  test "the release bundle and the installer name the same skills" do
    assert Aiur.MixProject.operator_skill_names() == OperatorSkills.skills() |> Map.keys() |> Enum.sort()
  end

  test "every named skill exists in the source tree" do
    for skill <- Aiur.MixProject.operator_skill_names() do
      assert File.dir?(Path.join(@source_root, skill)), "#{skill} is named for bundling but has no source directory"
    end
  end

  test "detects only present harnesses", %{home: home} do
    File.mkdir_p!(Path.join(home, ".codex/skills"))

    assert OperatorSkills.detect_harnesses(home: home, executable?: fn _ -> nil end) == [:codex]
    assert OperatorSkills.detect_harnesses(home: home, executable?: fn executable -> if executable == "claude", do: "/bin/claude" end) == [:claude, :codex]
  end
end
