defmodule Aiur.AgentRunner.SkillGateTest do
  @moduledoc """
  Mapped skills are mandatory (#7866): a missing or over-budget mapped set raises
  an alert naming the ticket, the skills and their reasons, and under
  `agent.skills.strict` it starts no worker.
  """

  use Aiur.TestSupport

  alias Aiur.AgentRunner.SkillGate
  alias Aiur.AgentSkills.Preload
  alias Aiur.Config.SkillsMapping

  setup do
    workspace = Aiur.TestSupport.tmp_root!("aiur-skill-gate")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  defp skill!(workspace, name, body) do
    dir = Path.join([workspace, ".claude", "skills", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: \"#{name}\"\n---\n\n#{body}\n")
  end

  defp issue, do: %Issue{id: "issue-7866", identifier: "7866", title: "Gate", description: "Do it.", labels: ["area:art"]}

  defp check(workspace, mapping) do
    parent = self()
    preload = Preload.resolve(issue(), workspace, settings: %{build_order: %{lanes: []}}, mapping: SkillsMapping.normalize(mapping))
    alert = fn topic, opts -> send(parent, {:alert, topic, opts}) end
    SkillGate.check(issue(), workspace, skill_preload: preload, alert_fun: alert)
  end

  describe "a mapped skill with no SKILL.md" do
    test "strict mode blocks and raises an attention alert naming the ticket, skill and reason", %{workspace: workspace} do
      assert {:blocked, message} = check(workspace, %{"strict" => true, "by_lane" => %{"art" => ["ghost-skill"]}})

      assert message =~ "#7866"
      assert message =~ "not installed: ghost-skill (lane:art)"
      assert_receive {:alert, "ticket.7866.skills.blocked", opts}
      assert opts[:needs_attention] == true
      assert opts[:message] == message
      assert %Issue{identifier: "7866"} = opts[:issue]
    end

    test "non-strict mode dispatches and raises a warning alert, not only a log line", %{workspace: workspace} do
      assert :ok = check(workspace, %{"by_lane" => %{"art" => ["ghost-skill"]}})

      assert_receive {:alert, "ticket.7866.skills.warning", opts}
      assert opts[:severity] == "warning"
      refute opts[:needs_attention]
      assert opts[:message] =~ "not installed: ghost-skill (lane:art)"
    end
  end

  describe "a mapped set over preload_max_bytes" do
    test "strict mode blocks and names the skills and their bytes against the budget", %{workspace: workspace} do
      skill!(workspace, "big", String.duplicate("x", 300))

      assert {:blocked, message} = check(workspace, %{"strict" => true, "preload_max_bytes" => 100, "by_lane" => %{"art" => ["big"]}})

      assert message =~ ~r/over agent.skills.preload_max_bytes: \d+\/100 bytes \(big \d+\)/
      assert_receive {:alert, "ticket.7866.skills.blocked", _opts}
    end

    test "non-strict mode dispatches with a warning alert", %{workspace: workspace} do
      skill!(workspace, "big", String.duplicate("x", 300))

      assert :ok = check(workspace, %{"preload_max_bytes" => 100, "by_lane" => %{"art" => ["big"]}})
      assert_receive {:alert, "ticket.7866.skills.warning", opts}
      assert opts[:message] =~ "/100 bytes"
    end
  end

  test "an installed mapped set inside the budget passes without an alert", %{workspace: workspace} do
    skill!(workspace, "small", "small")

    assert :ok = check(workspace, %{"strict" => true, "by_lane" => %{"art" => ["small"]}})
    refute_receive {:alert, _topic, _opts}, 50
  end

  describe "agent.skills.strict config" do
    test "accepts booleans and refuses anything else" do
      assert :ok = SkillsMapping.validate(%{"strict" => true})
      assert {:error, "agent.skills.strict must be true or false"} = SkillsMapping.validate(%{"strict" => "yes"})
      assert SkillsMapping.strict?(SkillsMapping.normalize(%{"strict" => true}))
      refute SkillsMapping.strict?(SkillsMapping.normalize(%{}))
    end
  end

  describe "dispatch" do
    test "strict mode with a missing mandatory skill starts no worker and pauses as a preflight failure" do
      root = Aiur.TestSupport.tmp_root!("skill-gate-dispatch")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
      File.mkdir_p!(root)
      codex = Path.join(root, "fake-codex")
      started = Path.join(root, "codex-started")
      File.write!(codex, "#!/bin/sh\ntouch #{started}\nexit 1\n")
      File.chmod!(codex, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(root, "workspaces"),
        codex_command: "#{codex} app-server",
        agent_skills: %{"strict" => true},
        max_turns: 1
      )

      issue = %Issue{id: "issue-gate", identifier: "MT-7866", title: "Gate", description: "Skills: ghost-skill", state: "In Progress", labels: []}
      parent = self()

      task =
        Task.async(fn ->
          AgentRunner.run(issue, parent, issue_state_fetcher: fn [_id] -> {:ok, [%{issue | state: "Done"}]} end)
        end)

      assert_receive {:worker_control_state, "issue-gate", :paused, %{kind: :before_run_failure}}, 10_000
      refute File.exists?(started)

      assert [log_path] = Path.wildcard(Path.join([root, "workspaces", "**", "MT-7866", "logs", "agent.ndjson"]))
      pause_log = File.read!(log_path)
      assert pause_log =~ "not installed: ghost-skill (override:Skills:)"

      Task.shutdown(task, :brutal_kill)
    end
  end
end
