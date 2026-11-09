defmodule Aiur.AgentSkills.PreloadBudgetTest do
  @moduledoc """
  Mapped skills are a worker's role instructions, so `preload_max_bytes` is a
  budget, never a cap: an over-budget mapped set is inlined whole and recorded.
  """
  use ExUnit.Case, async: true

  alias Aiur.AgentSkills.Preload
  alias Aiur.Config.SkillsMapping
  alias Aiur.Issue

  setup do
    workspace = Aiur.TestSupport.tmp_root!("aiur-preload-budget-test")
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

  defp issue(labels), do: %Issue{identifier: "ABC-1", title: "A task", description: "Do the work.", labels: labels}

  defp resolve(issue, workspace, mapping) do
    Preload.resolve(issue, workspace, settings: %{build_order: %{lanes: []}}, mapping: SkillsMapping.normalize(mapping))
  end

  describe "inline byte budget" do
    test "never moves a mapped skill to load on demand; an over-budget set is inlined whole and recorded", %{workspace: workspace} do
      skill!(workspace, "first", "First.", String.duplicate("a", 200))
      skill!(workspace, "second", "Second.", String.duplicate("b", 200))
      skill!(workspace, "third", "Third.", String.duplicate("c", 200) <> "THIRD SENTINEL")

      preload =
        resolve(issue(["area:art"]), workspace, %{
          "by_lane" => %{"art" => ["first", "second", "third"]},
          "preload_max_bytes" => 500
        })

      block = Preload.prompt_block(preload)

      assert Enum.map(preload.mapped, & &1.name) == ["first", "second", "third"]
      assert preload.bytes > 500
      assert Preload.over_budget?(preload)
      assert block =~ "THIRD SENTINEL"
      refute block =~ "load on demand)\n\n- `third`"
      refute block =~ "over the inline budget"
      assert Preload.summary(preload) =~ "over budget: #{preload.bytes}/500 bytes"
      assert %{skills_over_budget: true, skills_max_bytes: 500} = Preload.dispatch_record(preload)
      assert %{over_budget: true, max_bytes: 500} = Preload.report(preload)
    end

    test "a mapped set inside the budget is not over budget", %{workspace: workspace} do
      skill!(workspace, "first", "First.", "small")
      preload = resolve(issue(["area:art"]), workspace, %{"by_lane" => %{"art" => ["first"]}})

      refute Preload.over_budget?(preload)
      refute Preload.summary(preload) =~ "over budget"
    end
  end
end
