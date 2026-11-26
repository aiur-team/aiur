defmodule Aiur.AgentSkills.RegistryTest do
  @moduledoc """
  Which skills a workspace has installed, and how each `SKILL.md` description is
  read: the input every preload resolution starts from.
  """
  use ExUnit.Case, async: true

  alias Aiur.AgentSkills.Preload
  alias Aiur.Config.SkillsMapping
  alias Aiur.Issue

  setup do
    workspace = Aiur.TestSupport.tmp_root!("aiur-skill-registry-test")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  defp skill!(workspace, name, description, body, parents \\ []) do
    dir = Path.join([workspace, ".claude", "skills"] ++ parents ++ [name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: \"#{description}\"\n---\n\n#{body}\n")
    :ok
  end

  defp resolve(labels, workspace, mapping) do
    issue = %Issue{identifier: "ABC-1", title: "A task", description: "Do the work.", labels: labels}
    Preload.resolve(issue, workspace, settings: %{build_order: %{lanes: []}}, mapping: SkillsMapping.normalize(mapping))
  end

  describe "installed skills" do
    test "reads each skill once across every registered install path", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "BODY")

      installed = Preload.installed_skills(workspace)

      assert Map.has_key?(installed, "pixel-art")
      assert installed["pixel-art"].description == "Draw sprites."
      assert installed["pixel-art"].bytes > 0
    end

    test "indexes a vendored skill nested under its pack directory", %{workspace: workspace} do
      # Only a nested skill: a top-level-only read finds nothing here.
      skill!(workspace, "deep-skill", "Vendored.", "DEEP BODY", ["vendor", "pack"])

      installed = Preload.installed_skills(workspace)

      assert Map.keys(installed) == ["deep-skill"]
      assert installed["deep-skill"].description == "Vendored."

      preload = resolve(["area:art"], workspace, %{"by_lane" => %{"art" => ["deep-skill"]}})
      assert Enum.map(preload.mapped, & &1.name) == ["deep-skill"]
      assert preload.missing == []
    end

    # Guard for the nested scan's ordering and depth bound; a top-level-only read also passes it.
    test "a top-level skill wins a name collision with a nested one, and nesting is bounded", %{workspace: workspace} do
      skill!(workspace, "shared", "Top level.", "TOP")
      skill!(workspace, "shared", "Nested.", "NESTED", ["vendor", "pack"])
      skill!(workspace, "too-deep", "Too deep.", "DEEP", ["a", "b", "c"])

      installed = Preload.installed_skills(workspace)

      assert installed["shared"].description == "Top level."
      refute Map.has_key?(installed, "too-deep")
    end

    test "the nested scan does not follow a symlinked directory out of the install path", %{workspace: workspace} do
      outside = Path.join([workspace, "outside", "pack", "escaped"])
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "SKILL.md"), "---\nname: escaped\ndescription: \"Outside.\"\n---\n\nOUTSIDE\n")
      skill!(workspace, "inside", "Inside.", "INSIDE", ["real", "pack"])
      File.ln_s!(Path.join(workspace, "outside"), Path.join([workspace, ".claude", "skills", "vendor"]))

      installed = Preload.installed_skills(workspace)

      assert Map.has_key?(installed, "inside")
      refute Map.has_key?(installed, "escaped")
    end

    test "the nested scan lists a bounded number of directories per install path", %{workspace: workspace} do
      root = Path.join([workspace, ".claude", "skills"])
      for group <- 1..300, do: File.mkdir_p!(Path.join(root, "group-#{String.pad_leading("#{group}", 3, "0")}"))
      # Sorts after every group, so its directory is past the listing cap.
      skill!(workspace, "late-skill", "Late.", "LATE", ["zzz"])

      refute Map.has_key?(Preload.installed_skills(workspace), "late-skill")
    end

    test "an absent workspace resolves to no installed skills", %{workspace: workspace} do
      assert Preload.installed_skills(nil) == %{}
      assert Preload.installed_skills(Path.join(workspace, "missing")) == %{}
    end
  end

  describe "description parsing" do
    test "reads a quoted single-line description" do
      assert Preload.description("---\nname: x\ndescription: \"Quoted text.\"\n---\n\nbody") == "Quoted text."
    end

    test "reads an unquoted description" do
      assert Preload.description("---\nname: x\ndescription: Plain text\n---\n\nbody") == "Plain text"
    end

    test "joins a folded multi-line description" do
      assert Preload.description("---\nname: x\ndescription:\n  First part\n  second part\n---\n\nbody") == "First part second part"
    end

    test "returns nil without frontmatter" do
      assert Preload.description("# Just a heading") == nil
    end
  end
end
