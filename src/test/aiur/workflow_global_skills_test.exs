defmodule Aiur.WorkflowGlobalSkillsTest do
  use ExUnit.Case, async: false

  alias Aiur.Workflow

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-workflow-global-skills-test")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "agent.skills inherited from the global config (#7870)" do
    setup %{dir: dir} do
      previous_home = System.get_env("HOME")
      home = Path.join(dir, "home")
      File.mkdir_p!(Path.join(home, ".aiur"))
      System.put_env("HOME", home)
      on_exit(fn -> if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME") end)

      write_global = &File.write!(Path.join([home, ".aiur", "config"]), &1)
      project = Path.join([dir, "repo", ".aiur", "config"])
      File.mkdir_p!(Path.dirname(project))
      {:ok, write_global: write_global, project: project}
    end

    defp mapped_skills(path) do
      {:ok, %{config: config}} = Workflow.load(path)
      {:ok, settings} = Aiur.Config.Schema.parse(config)
      mapping = settings.agent.skills
      lane = &Aiur.Config.SkillsMapping.skills_for(mapping, "by_lane", &1)
      complexity = &Aiur.Config.SkillsMapping.skills_for(mapping, "by_complexity", &1)
      %{docs: lane.("docs"), ui: lane.("ui"), level_2: complexity.(2), max_bytes: mapping.preload_max_bytes}
    end

    test "a project adds lanes to the global map and replaces a shared key", ctx do
      ctx.write_global.("""
      agent:
        skills:
          preload_max_bytes: 1000
          by_lane:
            docs: [a]
            UI: [global-ui]
          by_complexity:
            "2": [global-two]
      """)

      File.write!(ctx.project, """
      tracker:
        kind: memory
      agent:
        skills:
          by_lane:
            ui: [b]
          by_complexity:
            2: [project-two]
      """)

      assert %{docs: ["a"], ui: ["b"], level_2: ["project-two"], max_bytes: 1000} = mapped_skills(ctx.project)
    end

    test "a project without agent.skills takes the whole global map", ctx do
      ctx.write_global.("agent:\n  skills:\n    by_lane:\n      docs: [a]\n")
      File.write!(ctx.project, "tracker:\n  kind: memory\n")

      assert %{docs: ["a"], ui: []} = mapped_skills(ctx.project)
    end

    # Regression guard: passes without the inheritance change too; it pins that
    # a broken global file can never stop a project load.
    test "a malformed global config does not stop the project loading", ctx do
      ctx.write_global.("agent: [unclosed")
      File.write!(ctx.project, "tracker:\n  kind: memory\nagent:\n  skills:\n    by_lane:\n      ui: [b]\n")

      assert %{docs: [], ui: ["b"]} = mapped_skills(ctx.project)
    end
  end
end
