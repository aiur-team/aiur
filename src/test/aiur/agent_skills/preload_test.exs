defmodule Aiur.AgentSkills.PreloadTest do
  @moduledoc """
  A worker's cold prompt should start with the skills that fit its ticket. This
  covers resolution (lane, feature, label, complexity, per-ticket override),
  ordering, the inline byte budget, the index of everything else, and the
  never-silent warning for a name that is not installed.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.AgentSkills.Preload
  alias Aiur.BuildOrder.Features
  alias Aiur.Config.SkillsMapping
  alias Aiur.Issue

  setup do
    workspace = Aiur.TestSupport.tmp_root!("aiur-preload-test")
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

  defp issue(labels, description \\ "Do the work.") do
    %Issue{identifier: "ABC-1", title: "A task", description: description, labels: labels}
  end

  defp ticket(number) do
    %Issue{identifier: Integer.to_string(number), title: "A task", description: "Do the work.", labels: ["area:art"]}
  end

  # A real build-order registry in a private directory, so the epic resolution
  # runs against the registry's own journal and projection rather than a stub.
  defp start_registry!(workspace) do
    dir = Path.join(workspace, "registry")
    File.mkdir_p!(dir)

    start_supervised!(
      {Features, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, general_epics: [], alert_fun: fn _, _, _ -> :ok end},
      id: make_ref(),
      restart: :temporary
    )
  end

  defp registry_meta(pid), do: [server: pid, source: "cli:executor", actor: "executor"]

  defp settings(lanes \\ []) do
    %{build_order: %{lanes: lanes}}
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

    test "a lane from a configured lane's label matcher counts", %{workspace: workspace} do
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
    test "label, lane, feature, epic and complexity combine in that order", %{workspace: workspace} do
      for name <- ~w(label-skill lane-skill feature-skill epic-skill complexity-skill) do
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
            "by_epic" => %{"v1-launch" => ["epic-skill"]},
            "by_complexity" => %{"3" => ["complexity-skill"]}
          },
          feature: "items-ui",
          epic: "v1-launch"
        )

      assert Enum.map(preload.mapped, & &1.reason) == ["label:design", "lane:art", "feature:items-ui", "epic:v1-launch", "complexity:3"]
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

  describe "feature mapping via the registry" do
    defmodule StubFeatures do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts), do: {:ok, opts}

      @impl true
      def handle_call({:read, {:owner, _number}}, _from, state) do
        {:reply, {:ok, %{feature: state[:feature]}}, state}
      end
    end

    defmodule TimeoutFeatures do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts), do: {:ok, opts}

      # Never replies, so the caller's registry timeout fires instead of the
      # test waiting on a sleep.
      @impl true
      def handle_call({:read, {:owner, _number}}, _from, state), do: {:noreply, state}
    end

    test "maps the owning feature from the registry", %{workspace: workspace} do
      skill!(workspace, "feature-skill", "Feature.", "FEATURE BODY")
      {:ok, pid} = StubFeatures.start_link(feature: "items-ui")
      issue = %Issue{identifier: "42", title: "A task", description: "Do the work.", labels: ["area:art"]}

      preload =
        resolve(issue, workspace, %{"by_feature" => %{"items-ui" => ["feature-skill"]}}, feature_server: pid)

      assert Enum.map(preload.mapped, &{&1.name, &1.reason}) == [{"feature-skill", "feature:items-ui"}]
    end

    test "a registry timeout does not crash and resolves without the feature", %{workspace: workspace} do
      skill!(workspace, "lane-skill", "Lane.", "LANE BODY")
      {:ok, pid} = TimeoutFeatures.start_link([])
      issue = %Issue{identifier: "42", title: "A task", description: "Do the work.", labels: ["area:art"]}

      preload =
        resolve(issue, workspace, %{"by_lane" => %{"art" => ["lane-skill"]}}, feature_server: pid)

      assert Enum.map(preload.mapped, & &1.name) == ["lane-skill"]
    end
  end

  describe "epic mapping via the registry" do
    test "maps the epic whose feature list holds the owning feature", %{workspace: workspace} do
      skill!(workspace, "epic-skill", "Epic.", "EPIC BODY")
      registry = start_registry!(workspace)
      {:ok, _} = Features.create("combat", %{label: "Combat"}, registry_meta(registry))
      {:ok, _} = Features.add("combat", [7], registry_meta(registry))
      {:ok, _} = Features.epic_create("v1-launch", %{label: "V1 launch", hue: 120}, registry_meta(registry))
      {:ok, _} = Features.epic_add("v1-launch", ["combat"], registry_meta(registry))

      preload =
        resolve(ticket(7), workspace, %{"by_epic" => %{"v1-launch" => ["epic-skill"]}}, feature_server: registry)

      assert Enum.map(preload.mapped, &{&1.name, &1.reason}) == [{"epic-skill", "epic:v1-launch"}]
      assert Preload.summary(preload) =~ "epic-skill (epic:v1-launch)"
      assert Preload.dispatch_record(preload).skill_reasons == %{"epic-skill" => "epic:v1-launch"}
    end

    test "a feature no epic holds resolves without an epic reason or an error", %{workspace: workspace} do
      skill!(workspace, "lane-skill", "Lane.", "LANE BODY")
      skill!(workspace, "epic-skill", "Epic.", "EPIC BODY")
      registry = start_registry!(workspace)
      {:ok, _} = Features.create("combat", %{label: "Combat"}, registry_meta(registry))
      {:ok, _} = Features.create("items", %{label: "Items"}, registry_meta(registry))
      {:ok, _} = Features.add("combat", [7], registry_meta(registry))
      # The epic exists and holds another feature, so the registry read runs and
      # finds no epic for "combat".
      {:ok, _} = Features.epic_create("v1-launch", %{label: "V1 launch", hue: 120}, registry_meta(registry))
      {:ok, _} = Features.epic_add("v1-launch", ["items"], registry_meta(registry))

      preload =
        resolve(ticket(7), workspace, %{"by_lane" => %{"art" => ["lane-skill"]}, "by_epic" => %{"v1-launch" => ["epic-skill"]}}, feature_server: registry)

      assert Enum.map(preload.mapped, &{&1.name, &1.reason}) == [{"lane-skill", "lane:art"}]
      assert preload.missing == []
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
      skill!(workspace, "third", "Third.", String.duplicate("c", 200))

      preload =
        resolve(issue(["area:art"]), workspace, %{
          "by_lane" => %{"art" => ["first", "second", "third"]},
          "preload_max_bytes" => 500
        })

      assert Enum.map(preload.mapped, & &1.name) == ["first", "second"]
      assert Enum.map(preload.truncated, & &1.name) == ["third"]
      assert preload.bytes <= 500
      assert Preload.prompt_block(preload) =~ "### Mapped skills over the inline budget"
      assert Preload.summary(preload) =~ "truncated: third"
    end
  end

  describe "recommended skills" do
    test "list name, description and load path in their own section without inlining", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "PIXEL ART BODY")
      skill!(workspace, "sprite-sheets", "Pack sprite sheets.", "SPRITE SHEET BODY", ["vendor", "pack"])
      skill!(workspace, "unrelated", "CI plumbing.", "UNRELATED BODY")

      preload =
        resolve(issue(["area:art"]), workspace, %{
          "by_lane" => %{"art" => ["pixel-art"]},
          "recommended" => %{"by_lane" => %{"art" => ["sprite-sheets", "pixel-art"]}}
        })

      # A skill both mapped and recommended stays mapped.
      assert Enum.map(preload.mapped, & &1.name) == ["pixel-art"]
      assert [%{name: "sprite-sheets", reason: "lane:art", path: path}] = preload.recommended
      assert path == ".claude/skills/vendor/pack/sprite-sheets/SKILL.md"

      block = Preload.prompt_block(preload)
      assert block =~ "### Recommended skills (load on demand)"
      assert block =~ "- `sprite-sheets` (lane:art) — Pack sprite sheets.\n  Load: `.claude/skills/vendor/pack/sprite-sheets/SKILL.md`"
      refute block =~ "SPRITE SHEET BODY"
      # Not repeated in the full index.
      assert block |> String.split("`sprite-sheets`") |> length() == 2
      assert position(block, "### Recommended skills") < position(block, "### Other installed skills")
      assert Preload.dispatch_record(preload).skills_recommended == ["sprite-sheets"]
    end

    test "never count against preload_max_bytes", %{workspace: workspace} do
      skill!(workspace, "big", "Big.", String.duplicate("x", 2_000))

      preload =
        resolve(issue(["area:art"]), workspace, %{
          "preload_max_bytes" => 100,
          "recommended" => %{"by_lane" => %{"art" => ["big"]}}
        })

      assert Enum.map(preload.recommended, & &1.name) == ["big"]
      assert preload.truncated == []
      assert preload.bytes == 0
    end

    test "a recommended name not installed is reported as missing", %{workspace: workspace} do
      skill!(workspace, "pixel-art", "Draw sprites.", "PIXEL ART BODY")

      {preload, _log} =
        with_log(fn -> resolve(issue(["area:art"]), workspace, %{"recommended" => %{"by_lane" => %{"art" => ["ghost-skill"]}}}) end)

      assert preload.recommended == []
      assert [%{name: "ghost-skill", reason: "recommended, lane:art"}] = preload.missing
      assert preload.configured?
    end

    test "validation names a bad recommended dimension or skill" do
      assert SkillsMapping.validate(%{"recommended" => %{"by_lane" => %{"art" => ["ok-skill"]}}}) == :ok
      assert {:error, "agent.skills.recommended has unknown keys by_mood" <> _} = SkillsMapping.validate(%{"recommended" => %{"by_mood" => %{}}})

      assert {:error, "agent.skills.recommended.by_lane.art names invalid skills a/b" <> _} =
               SkillsMapping.validate(%{"recommended" => %{"by_lane" => %{"art" => ["a/b"]}}})

      assert SkillsMapping.validate(%{"recommended" => ["x"]}) == {:error, "agent.skills.recommended must be a map"}
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

    test "indexes a vendored skill nested under its pack directory", %{workspace: workspace} do
      # Only a nested skill: a top-level-only read finds nothing here.
      skill!(workspace, "deep-skill", "Vendored.", "DEEP BODY", ["vendor", "pack"])

      installed = Preload.installed_skills(workspace)

      assert Map.keys(installed) == ["deep-skill"]
      assert installed["deep-skill"].description == "Vendored."

      preload = resolve(issue(["area:art"]), workspace, %{"by_lane" => %{"art" => ["deep-skill"]}})
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
