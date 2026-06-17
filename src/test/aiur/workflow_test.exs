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

  describe ".aiurconfig pure-YAML parse" do
    test "a pure-YAML .aiurconfig with no prompt_file loads with an empty prompt", %{dir: dir} do
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
      assert loaded.prompt_template == ""
    end

    test "a .aiurconfig that decodes to a non-map is rejected", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "- not\n- a\n- map\n")

      assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(path)
    end
  end

  describe "prompt_file resolution" do
    test "prompt_file loads the sibling template as the prompt", %{dir: dir} do
      File.write!(Path.join(dir, "prompt.md"), "You are working on {{ issue.identifier }}.\n")

      path = Path.join(dir, ".aiurconfig")

      File.write!(path, """
      tracker:
        kind: github
      prompt_file: prompt.md
      """)

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.prompt == "You are working on {{ issue.identifier }}."
      assert loaded.prompt_template == "You are working on {{ issue.identifier }}."
      assert loaded.config["tracker"]["kind"] == "github"
    end

    test "prompt_file resolves relative to the config dir, not cwd", %{dir: dir} do
      subdir = Path.join(dir, "nested")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "prompt.md"), "Nested prompt body.\n")

      path = Path.join(subdir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nprompt_file: prompt.md\n")

      elsewhere = Path.join(dir, "elsewhere")
      File.mkdir_p!(elsewhere)

      File.cd!(elsewhere, fn ->
        assert {:ok, loaded} = Workflow.load(path)
        assert loaded.prompt == "Nested prompt body."
      end)
    end

    test "an empty prompt_file is treated as absent", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nprompt_file: \"\"\n")

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.prompt == ""
    end

    test "a prompt_file pointing at a missing file is a clear error", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nprompt_file: missing.md\n")

      resolved = Path.expand("missing.md", dir)
      assert {:error, {:missing_prompt_file, ^resolved, :enoent}} = Workflow.load(path)
    end
  end

  describe "hooks_file resolution" do
    test "hooks_file loads the sibling file as the hooks map", %{dir: dir} do
      File.write!(Path.join(dir, ".aiurhooks"), "after_create: echo created\nbase_setup: mix deps.get\n")
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nhooks_file: .aiurhooks\n")

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["hooks"]["after_create"] == "echo created"
      assert loaded.config["hooks"]["base_setup"] == "mix deps.get"
    end

    test "hooks_file takes precedence over an inline hooks block", %{dir: dir} do
      File.write!(Path.join(dir, ".aiurhooks"), "after_create: from file\n")
      path = Path.join(dir, ".aiurconfig")

      File.write!(path, """
      tracker:
        kind: memory
      hooks:
        after_create: inline ignored
      hooks_file: .aiurhooks
      """)

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["hooks"]["after_create"] == "from file"
    end

    test "an inline hooks block still loads when no hooks_file is set", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")

      File.write!(path, """
      tracker:
        kind: memory
      hooks:
        after_create: inline create
      """)

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["hooks"]["after_create"] == "inline create"
    end

    test "hooks_file resolves relative to the config dir, not cwd", %{dir: dir} do
      subdir = Path.join(dir, "nested")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, ".aiurhooks"), "after_create: nested hook\n")
      path = Path.join(subdir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nhooks_file: .aiurhooks\n")

      File.cd!(dir, fn ->
        assert {:ok, loaded} = Workflow.load(path)
        assert loaded.config["hooks"]["after_create"] == "nested hook"
      end)
    end

    test "a hooks_file pointing at a missing file is a clear error", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nhooks_file: missing.aiurhooks\n")

      resolved = Path.expand("missing.aiurhooks", dir)
      assert {:error, {:missing_hooks_file, ^resolved, :enoent}} = Workflow.load(path)
    end

    test "base_setup parses through the config schema", %{dir: dir} do
      File.write!(Path.join(dir, ".aiurhooks"), "base_setup: mix compile\n")
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nhooks_file: .aiurhooks\n")

      assert {:ok, loaded} = Workflow.load(path)
      assert {:ok, settings} = Aiur.Config.Schema.parse(loaded.config)
      assert settings.hooks.base_setup == "mix compile"
    end
  end

  describe "config path resolution" do
    test "workflow_file_path defaults to .aiurconfig in cwd when app env unset", %{dir: dir} do
      File.cd!(dir, fn ->
        Application.delete_env(:aiur, :workflow_file_path)
        assert Path.basename(Workflow.workflow_file_path()) == ".aiurconfig"
      end)
    end

    test "an explicit workflow_file_path override wins, with arbitrary basename + pure-YAML", %{
      dir: dir
    } do
      override = Path.join(dir, "operator.config")
      File.write!(override, "tracker:\n  kind: github\ngithub:\n  repo: owner/name\n")

      File.cd!(dir, fn ->
        Application.put_env(:aiur, :workflow_file_path, override)
        assert Workflow.workflow_file_path() == override
        assert {:ok, loaded} = Workflow.load(Workflow.workflow_file_path())
        assert loaded.config["github"]["repo"] == "owner/name"
      end)
    end

    test "resolve_config_path prefers local, else global, else local for the error", %{dir: dir} do
      local = Path.join(dir, "local.aiurconfig")
      global = Path.join(dir, "global.aiurconfig")

      # neither present -> local path (so the caller surfaces "run aiur init")
      assert Workflow.resolve_config_path(local, global) == local

      File.write!(global, "tracker:\n  kind: memory\n")
      # only global -> global
      assert Workflow.resolve_config_path(local, global) == global

      File.write!(local, "tracker:\n  kind: memory\n")
      # both -> local wins
      assert Workflow.resolve_config_path(local, global) == local
    end
  end
end
