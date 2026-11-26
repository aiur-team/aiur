defmodule Aiur.AgentRunner.TurnPromptSkillsTest do
  @moduledoc """
  A first turn that starts a new session carries the ticket's skill preload
  block; a resumed session gets only a pointer to its mapped skills, and later
  turns get neither.
  """

  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnPrompt
  alias Aiur.Issue

  setup do
    workspace = Aiur.TestSupport.tmp_root!("turn-prompt-skills")
    dir = Path.join([workspace, ".claude", "skills", "pixel-art"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\nname: pixel-art\ndescription: \"Draw sprites.\"\n---\n\nPIXEL ART BODY\n")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "a cold first turn carries the skills block", %{workspace: workspace} do
    prompt = TurnPrompt.build_turn_prompt(%Issue{id: "1", identifier: "1", title: "t", state: "todo"}, [workspace: workspace], 1, nil)

    assert prompt =~ "## Skills for this ticket"
    assert prompt =~ "`pixel-art`"
  end

  test "a continuation first turn carries the skills block", %{workspace: workspace} do
    prompt = TurnPrompt.build_turn_prompt(%Issue{id: "1", identifier: "1", title: "t", state: "rework"}, [workspace: workspace], 1, nil)

    assert prompt =~ "## Skills for this ticket"
    assert prompt =~ "`pixel-art`"
  end

  test "a resumed first turn points at its mapped skills without repeating the block", %{workspace: workspace} do
    issue = %Issue{id: "1", identifier: "1", title: "t", state: "in-progress", labels: ["skills:pixel-art"]}
    prompt = TurnPrompt.build_turn_prompt(issue, [workspace: workspace, resumed: true], 1, nil)

    assert prompt =~ "## Skills for this ticket (pointer)"
    assert prompt =~ "- `pixel-art` (override:skills:pixel-art) — `#{Path.join([workspace, ".claude", "skills", "pixel-art", "SKILL.md"])}`"
    refute prompt =~ "PIXEL ART BODY"
  end

  test "a resumed first turn with no mapped skills gets no skills text", %{workspace: workspace} do
    prompt = TurnPrompt.build_turn_prompt(%Issue{id: "1", identifier: "1", title: "t", state: "in-progress"}, [workspace: workspace, resumed: true], 1, nil)

    refute prompt =~ "Skills for this ticket"
    refute prompt =~ "pixel-art"
  end

  test "continuation turns 2..N carry no skills text", %{workspace: workspace} do
    issue = %Issue{id: "1", identifier: "1", title: "t", state: "in-progress", labels: ["skills:pixel-art"]}
    prompt = TurnPrompt.build_turn_prompt(issue, [workspace: workspace], 2, 5)

    refute prompt =~ "Skills for this ticket"
    refute prompt =~ "pixel-art"
  end
end
