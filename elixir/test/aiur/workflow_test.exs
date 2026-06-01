defmodule Aiur.WorkflowTest do
  use ExUnit.Case, async: false

  alias Aiur.Workflow

  setup do
    previous = Application.get_env(:aiur, :workflow_file_path)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :workflow_file_path)
      else
        Application.put_env(:aiur, :workflow_file_path, previous)
      end
    end)

    dir = Path.join(System.tmp_dir!(), "aiur-workflow-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "characterization: legacy WORKFLOW.md" do
    test "fenced front matter loads config and body prompt", %{dir: dir} do
      path = Path.join(dir, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker:
        kind: github
      github:
        repo: owner/name
      ---
      You are a helpful agent.
      """)

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["tracker"]["kind"] == "github"
      assert loaded.config["github"]["repo"] == "owner/name"
      assert loaded.prompt == "You are a helpful agent."
    end

    test "a fence-less WORKFLOW.md is treated as all prompt body, empty config", %{dir: dir} do
      path = Path.join(dir, "WORKFLOW.md")
      File.write!(path, "Just a prompt, no front matter.\n")

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config == %{}
      assert loaded.prompt == "Just a prompt, no front matter."
    end
  end

  describe ".aiurconfig detection and pure-YAML parse" do
    test "a pure-YAML .aiurconfig loads as config with an empty prompt", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")

      File.write!(path, """
      tracker:
        kind: github
      github:
        repo: owner/name
      max_concurrent_agents: 5
      """)

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["tracker"]["kind"] == "github"
      assert loaded.config["github"]["repo"] == "owner/name"
      assert loaded.config["max_concurrent_agents"] == 5
      assert loaded.prompt == ""
    end

    test "workflow_file_path prefers .aiurconfig over WORKFLOW.md in the run folder", %{dir: dir} do
      File.write!(Path.join(dir, ".aiurconfig"), "tracker:\n  kind: memory\n")
      File.write!(Path.join(dir, "WORKFLOW.md"), "---\ntracker:\n  kind: github\n---\nbody\n")

      File.cd!(dir, fn ->
        Application.delete_env(:aiur, :workflow_file_path)
        assert Path.basename(Workflow.workflow_file_path()) == ".aiurconfig"
      end)
    end

    test "an explicit workflow_file_path override wins over .aiurconfig", %{dir: dir} do
      File.write!(Path.join(dir, ".aiurconfig"), "tracker:\n  kind: memory\n")
      override = Path.join(dir, "WORKFLOW.md")
      File.write!(override, "---\ntracker:\n  kind: github\n---\nbody\n")

      File.cd!(dir, fn ->
        Application.put_env(:aiur, :workflow_file_path, override)
        assert Workflow.workflow_file_path() == override
      end)
    end

    test "a .aiurconfig that decodes to a non-map is rejected", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "- not\n- a\n- map\n")

      assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(path)
    end

    test "falls back to WORKFLOW.md when no .aiurconfig is present", %{dir: dir} do
      File.write!(Path.join(dir, "WORKFLOW.md"), "---\ntracker:\n  kind: github\n---\nbody\n")

      File.cd!(dir, fn ->
        Application.delete_env(:aiur, :workflow_file_path)
        assert Path.basename(Workflow.workflow_file_path()) == "WORKFLOW.md"
      end)
    end
  end
end
