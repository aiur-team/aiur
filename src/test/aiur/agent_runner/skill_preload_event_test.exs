defmodule Aiur.AgentRunner.SkillPreloadEventTest do
  @moduledoc """
  The skill decision has to survive the run: the dispatch record answers "which
  skills did this worker get, and why" after the agent list row is gone.
  """

  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.AgentRunner.SkillPreloadEvent
  alias Aiur.AgentSkills.Preload
  alias Aiur.Config.SkillsMapping
  alias Aiur.Issue

  setup do
    workspace = Aiur.TestSupport.tmp_root!("skill-preload-event")
    skill_dir = Path.join([workspace, ".claude", "skills", "pixel-art"])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: pixel-art\ndescription: \"Draw sprites.\"\n---\n\nPIXEL ART BODY\n")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  defp preload(workspace) do
    issue = %Issue{identifier: "ABC-1", title: "A task", description: "Skills: ghost-skill\n", labels: ["area:art"]}

    Preload.resolve(issue, workspace,
      settings: %{},
      mapping: SkillsMapping.normalize(%{"by_lane" => %{"art" => ["pixel-art"]}})
    )
  end

  test "records the resolved skills, reasons and missing names in the ticket's log", %{workspace: workspace} do
    assert :ok = SkillPreloadEvent.write(workspace, nil, preload(workspace))

    ndjson = File.read!(Path.join(workspace, "logs/agent.ndjson"))
    markdown = File.read!(Path.join(workspace, "logs/agent.md"))

    assert ndjson =~ ~s("event":"skill_preload")
    assert ndjson =~ ~s("skills":["pixel-art"])
    assert ndjson =~ ~s("skill_reasons":{"pixel-art":"lane:art"})
    assert ndjson =~ ~s("skills_missing":["ghost-skill"])
    assert markdown =~ "pixel-art (lane:art)"
    assert markdown =~ "missing: ghost-skill"
  end

  test "the session execution report carries the preload summary", %{workspace: workspace} do
    issue = %Issue{id: "gid-abc-1", identifier: "ABC-1", title: "A task", labels: ["area:art"]}
    session = %{backend: :claude, model: "opus"}

    assert :ok = SessionLifecycle.report_session_execution(self(), issue, session, preload(workspace))

    assert_receive {:session_execution_info, "gid-abc-1", info}, 1_000
    assert info.skills == "skills: pixel-art (lane:art); missing: ghost-skill"
  end

  test "writes nothing for a remote worker host or an unresolved preload", %{workspace: workspace} do
    assert :ok = SkillPreloadEvent.write(workspace, "remote-host", preload(workspace))
    assert :ok = SkillPreloadEvent.write(workspace, nil, nil)
    assert :ok = SkillPreloadEvent.write(nil, nil, preload(workspace))

    refute File.exists?(Path.join(workspace, "logs/agent.ndjson"))
  end
end
