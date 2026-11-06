defmodule Aiur.AgentSkills.PreloadTest do
  @moduledoc """
  A worker's cold prompt should start with the skills that fit its ticket. This
  covers resolution (lane, feature, label, complexity, per-ticket override),
  ordering, the inline byte budget, the index of everything else, and the
  never-silent warning for a name that is not installed.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.Config.SkillsMapping
  alias Aiur.AgentSkills.Preload
  alias Aiur.Issue

  setup do
    workspace = Aiur.TestSupport.tmp_root!("aiur-preload-test")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  defp skill!(workspace, name, description, body) do
    dir = Path.join([workspace, ".claude", "skills", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: \"#{description}\"\n---\n\n#{body}\n")
    :ok
  end

  defp issue(labels, description \\ "Do the work.") do
    %Issue{identifier: "ABC-1", title: "A task", description: description, labels: labels}
  end

  defp settings(general_epics \\ []) do
    %{build_order: %{general_epics: general_epics}}
  end

  defp resolve(issue, workspace, mapping, opts \\ []) do
    Preload.resolve(issue, workspace, Keyword.merge([settings: settings(), mapping: SkillsMapping.normalize(mapping)], opts))
  end

  describe "lane mapping" do
    test "preloads the skills a lane maps to, in configured order, with the reason", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "PIXEL ART BODY")
      skill!(workspace, "palette", "Pick colours.", "PALETTE BODY")

      preload =
        resolve(issue(["area:art"]), workspace, %{
          "by_lane" => %{"art" => ["pixel-art", "palette"]}
        })

      assert Enum.map(preload.mapped, & &1.name) == ["pixel-art", "palette"]
      assert Enum.map(preload.mapped, & &1.reason) == ["lane:art", "lane:art"]
      assert preload.bytes > 0
      assert preload.lanes == ["art"]
    end

    test "combines the skills of every lane a ticket carries", %{workspace: workspace} do
      skill!(workspace, "docs-style", "House style.", "DOCS BODY")
      skill!(workspace, "ui-kit", "Component kit.", "UI BODY")

      preload =
        resolve(issue(["build-lane:docs", "area:ui"]), workspace, %{
          "by_lane" => %{"docs" => ["docs-style"], "ui" => ["ui-kit"]}
        })

      # Prefix order, not label order: lane:, then area:, then build-lane:.
      assert Enum.map(preload.mapped, &{&1.name, &1.reason}) == [
               {"ui-kit", "lane:ui"},
               {"docs-style", "lane:docs"}
             ]
    end

    test "a lane from a configured general epic's label matcher counts", %{workspace: workspace} do
      skill!(workspace, "infra-runbook", "Operate infra.", "INFRA BODY")

      preload =
        Preload.resolve(issue(["area:infra"]), workspace,
          settings: settings([%{key: "infra", labels: ["area:infra"]}]),
          mapping: SkillsMapping.normalize(%{"by_lane" => %{"infra" => ["infra-runbook"]}})
        )

      assert Enum.map(preload.mapped, &{&1.name, &1.reason}) == [{"infra-runbook", "lane:infra"}]
    end
  end

  describe "merge order" do
    test "label, lane, feature and complexity combine in that order", %{workspace: workspace} do
      for name <- ~w(label-skill lane-skill feature-skill complexity-skill) do
        skill!(workspace, name, "#{name} description.", "#{name} body")
      end

      preload =
        resolve(
          issue(["design", "area:art", "complexity:3"]),
          workspace,
          %{
            "by_label" => %{"design" => ["label-skill"]},
            "by_lane" => %{"art" => ["lane-skill"]},
            "by_feature" => %{"items-ui" => ["feature-skill"]},
            "by_complexity" => %{"3" => ["complexity-skill"]}
          },
          feature: "items-ui"
        )

      assert Enum.map(preload.mapped, & &1.reason) == ["label:design", "lane:art", "feature:items-ui", "complexity:3"]
    end

    test "a skill named by two sources keeps the earlier reason", %{workspace: workspace} do
      skill!(workspace, "shared", "Shared.", "SHARED BODY")

      preload =
        resolve(issue(["design", "area:art"]), workspace, %{
          "by_label" => %{"design" => ["shared"]},
          "by_lane" => %{"art" => ["shared"]}
        })

      assert [%{name: "shared", reason: "label:design"}] = preload.mapped
    end

    test "no configured mapping still resolves an empty preload", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "PIXEL ART BODY")

      preload = resolve(issue(["area:art"]), workspace, %{})

      assert preload.mapped == []
      assert preload.missing == []
      assert preload.lanes == ["art"]
      refute Preload.mapped?(preload)
    end
  end

  describe "per-ticket override" do
    test "a `skills:` label adds a configured label's skills", %{workspace: workspace} do
      skill!(workspace, "lane-skill", "Lane.", "LANE BODY")
      skill!(workspace, "extra-skill", "Extra.", "EXTRA BODY")

      preload =
        resolve(issue(["area:art", "skills:extra"]), workspace, %{
          "by_lane" => %{"art" => ["lane-skill"]},
          "by_label" => %{"extra" => ["extra-skill"]}
        })

      assert Enum.map(preload.mapped, &{&1.name, &1.reason}) == [
               {"extra-skill", "override:skills:extra"},
               {"lane-skill", "lane:art"}
             ]
    end

    test "a `skills:` label naming no configured entry adds one skill by name", %{workspace: workspace} do
      skill!(workspace, "shader-tips", "Shaders.", "SHADER BODY")

      preload = resolve(issue(["skills:shader-tips"]), workspace, %{})

      assert Enum.map(preload.mapped, &{&1.name, &1.reason}) == [{"shader-tips", "override:skills:shader-tips"}]
    end

    test "a `Skills:` body line adds skills ahead of the mapped set", %{workspace: workspace} do
      skill!(workspace, "lane-skill", "Lane.", "LANE BODY")
      skill!(workspace, "shader-tips", "Shaders.", "SHADER BODY")

      preload =
        resolve(
          issue(["area:art"], "Notes\n\nSkills: shader-tips\n"),
          workspace,
          %{"by_lane" => %{"art" => ["lane-skill"]}}
        )

      assert Enum.map(preload.mapped, &{&1.name, &1.reason}) == [
               {"shader-tips", "override:Skills:"},
               {"lane-skill", "lane:art"}
             ]
    end

    test "a `Skills only:` body line replaces the configured set", %{workspace: workspace} do
      skill!(workspace, "lane-skill", "Lane.", "LANE BODY")
      skill!(workspace, "shader-tips", "Shaders.", "SHADER BODY")

      preload =
        resolve(
          issue(["area:art"], "Skills only: shader-tips\n"),
          workspace,
          %{"by_lane" => %{"art" => ["lane-skill"]}}
        )

      assert Enum.map(preload.mapped, &{&1.name, &1.reason}) == [{"shader-tips", "override:Skills only:"}]
    end

    test "a `Skills:` line inside a fenced code block is documentation, not an override", %{workspace: workspace} do
      skill!(workspace, "lane-skill", "Lane.", "LANE BODY")

      preload =
        resolve(
          issue(["area:art"], "How to set skills:\n\n```\nSkills: not-a-real-skill\n```\n"),
          workspace,
          %{"by_lane" => %{"art" => ["lane-skill"]}}
        )

      assert Enum.map(preload.mapped, & &1.name) == ["lane-skill"]
      assert preload.missing == []
    end
  end

  describe "unknown skill names" do
    test "land in missing, log a warning, and keep the installed mapped skills", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "PIXEL ART BODY")

      log =
        capture_log(fn ->
          preload = resolve(issue(["area:art"], "Skills: ghost-skill\n"), workspace, %{"by_lane" => %{"art" => ["pixel-art"]}})
          send(self(), {:preload, preload})
        end)

      assert_received {:preload, preload}
      assert Enum.map(preload.mapped, & &1.name) == ["pixel-art"]
      assert Enum.map(preload.missing, &{&1.name, &1.reason}) == [{"ghost-skill", "override:Skills:"}]
      assert log =~ "unknown skill"
      assert log =~ "ghost-skill"
      refute Enum.any?(preload.index, &(&1.name == "ghost-skill"))
    end

    test "render a warning section in the prompt block instead of being dropped", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "PIXEL ART BODY")
      preload = resolve(issue(["area:art"], "Skills: ghost-skill\n"), workspace, %{"by_lane" => %{"art" => ["pixel-art"]}})

      block = Preload.prompt_block(preload)

      assert block =~ "### Mapped skills not installed here"
      assert block =~ "`ghost-skill` (override:Skills:)"
      assert block =~ "Do not stall on them"
    end
  end

  describe "prompt block" do
    test "inlines mapped skill instructions first and indexes every other installed skill", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "PIXEL ART BODY")
      skill!(workspace, "unrelated", "CI plumbing.", "UNRELATED BODY")

      block = Preload.prompt_block(resolve(issue(["area:art"]), workspace, %{"by_lane" => %{"art" => ["pixel-art"]}}))

      assert block =~ "## Skills for this ticket"
      assert block =~ "#### `pixel-art` — mapped by lane:art"
      assert block =~ "PIXEL ART BODY"
      assert block =~ "### Other installed skills (load on demand)"
      assert block =~ "`unrelated` — CI plumbing."
      # The index lists the unrelated skill only as a name and description.
      refute block =~ "UNRELATED BODY"
      # Mapped skills never repeat in the index.
      assert block |> String.split("`pixel-art`") |> length() == 2
      assert position(block, "PIXEL ART BODY") < position(block, "### Other installed skills")
    end

    test "is empty when the workspace has no readable skills", %{workspace: workspace} do
      assert Preload.prompt_block(resolve(issue(["area:art"]), workspace, %{})) == ""
    end
  end

  defp position(text, needle), do: text |> :binary.match(needle) |> elem(0)

  describe "inline byte budget" do
    test "keeps the first skills inside the budget and lists the rest to load on demand", %{workspace: workspace} do
      skill!(workspace, "first", "First.", String.duplicate("a", 200))
      skill!(workspace, "second", "Second.", String.duplicate("b", 200))

      preload =
        resolve(issue(["area:art"]), workspace, %{
          "by_lane" => %{"art" => ["first", "second"]},
          "preload_max_bytes" => 400
        })

      assert Enum.map(preload.mapped, & &1.name) == ["first"]
      assert Enum.map(preload.truncated, & &1.name) == ["second"]
      assert preload.bytes <= 400
      assert Preload.prompt_block(preload) =~ "### Mapped skills over the inline budget"
      assert Preload.summary(preload) =~ "truncated: second"
    end
  end

  describe "config reading" do
    test "re-resolves from the settings it is given, so a config edit applies to the next dispatch", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "PIXEL ART BODY")
      skill!(workspace, "palette", "Pick colours.", "PALETTE BODY")

      first = Preload.resolve(issue(["area:art"]), workspace, settings: %{agent: %{skills: %{"by_lane" => %{"art" => ["pixel-art"]}}}})
      second = Preload.resolve(issue(["area:art"]), workspace, settings: %{agent: %{skills: %{"by_lane" => %{"art" => ["palette"]}}}})

      assert Enum.map(first.mapped, & &1.name) == ["pixel-art"]
      assert Enum.map(second.mapped, & &1.name) == ["palette"]
    end

    test "a settings value without agent.skills resolves to no configured skills", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "PIXEL ART BODY")

      preload = Preload.resolve(issue(["area:art"]), workspace, settings: %{})

      assert preload.mapped == []
      refute preload.configured?
    end
  end

  describe "dispatch record" do
    test "names each skill, its reason, the missing names and the byte count", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "PIXEL ART BODY")
      preload = resolve(issue(["area:art"], "Skills: ghost-skill\n"), workspace, %{"by_lane" => %{"art" => ["pixel-art"]}})
      record = Preload.dispatch_record(preload)

      assert record.event == :skill_preload
      assert record.skills == ["pixel-art"]
      assert record.skill_reasons == %{"pixel-art" => "lane:art"}
      assert record.skills_missing == ["ghost-skill"]
      assert record.skill_reasons_missing == %{"ghost-skill" => "override:Skills:"}
      assert record.skills_bytes == preload.bytes
      assert record.skill_lanes == ["art"]
      assert is_binary(record.last_message)
      assert record.last_message =~ "pixel-art (lane:art)"
      assert record.last_message =~ "missing: ghost-skill"
    end
  end

  describe "installed skills" do
    test "reads each skill once across every registered install path", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "BODY")

      installed = Preload.installed_skills(workspace)

      assert Map.has_key?(installed, "pixel-art")
      assert installed["pixel-art"].description == "Draw sprites."
      assert installed["pixel-art"].bytes > 0
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
