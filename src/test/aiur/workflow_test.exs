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
      File.write!(Path.join(dir, ".aiurhooks"), "after_create: echo created\nbefore_run: mix deps.get\n")
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nhooks_file: .aiurhooks\n")

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["hooks"]["after_create"] == "echo created"
      assert loaded.config["hooks"]["before_run"] == "mix deps.get"
    end

    test "the new .aiur/config layout resolves hooks_file: hooks relative to .aiur/", %{dir: dir} do
      aiur = Path.join(dir, ".aiur")
      File.mkdir_p!(aiur)
      File.write!(Path.join(aiur, "hooks"), "after_create: echo created\n")
      path = Path.join(aiur, "config")
      File.write!(path, "tracker:\n  kind: memory\nhooks_file: hooks\n")

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["hooks"]["after_create"] == "echo created"
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

    test "a hooks_file that isn't a YAML map is an invalid_hooks_file error", %{dir: dir} do
      File.write!(Path.join(dir, ".aiurhooks"), "- just\n- a\n- list\n")
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nhooks_file: .aiurhooks\n")

      resolved = Path.expand(".aiurhooks", dir)
      assert {:error, {:invalid_hooks_file, ^resolved, _reason}} = Workflow.load(path)
    end

    test "an empty hooks_file value falls back to the inline hooks block", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")

      File.write!(path, """
      tracker:
        kind: memory
      hooks:
        after_create: inline create
      hooks_file: ""
      """)

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["hooks"]["after_create"] == "inline create"
    end
  end

  describe "alerts_file resolution" do
    test "a relative alerts_file resolves to an absolute path next to the config dir, not cwd", %{dir: dir} do
      aiur = Path.join(dir, ".aiur")
      File.mkdir_p!(aiur)
      path = Path.join(aiur, "config")
      File.write!(path, "tracker:\n  kind: memory\nalerts:\n  enabled: true\n  alerts_file: alerts\n")

      elsewhere = Path.join(dir, "elsewhere")
      File.mkdir_p!(elsewhere)

      File.cd!(elsewhere, fn ->
        assert {:ok, loaded} = Workflow.load(path)
        assert loaded.config["alerts"]["alerts_file"] == Path.join(aiur, "alerts")
      end)
    end

    test "an absolute alerts_file is left untouched", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nalerts:\n  alerts_file: /etc/aiur/alerts.yaml\n")

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["alerts"]["alerts_file"] == "/etc/aiur/alerts.yaml"
    end

    test "a ~/ alerts_file is left untouched for later expansion", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nalerts:\n  alerts_file: ~/my-alerts.yaml\n")

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["alerts"]["alerts_file"] == "~/my-alerts.yaml"
    end

    test "an absent alerts_file leaves the alerts block unchanged", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nalerts:\n  enabled: true\n")

      assert {:ok, loaded} = Workflow.load(path)
      refute Map.has_key?(loaded.config["alerts"], "alerts_file")
    end
  end

  describe "prewarm base_build_file resolution" do
    test "base_build_file loads the sibling script into prewarm.base_build", %{dir: dir} do
      File.write!(Path.join(dir, "prewarm"), "mix deps.get && mix compile\n")
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nprewarm:\n  enabled: true\n  base_build_file: prewarm\n")

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["prewarm"]["base_build"] == "mix deps.get && mix compile"
    end

    test "a base_build_file pointing at a missing file is a clear error", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nprewarm:\n  enabled: true\n  base_build_file: missing\n")

      resolved = Path.expand("missing", dir)
      assert {:error, {:missing_prewarm_file, ^resolved, :enoent}} = Workflow.load(path)
    end

    test "an inline base_build is left unchanged when no base_build_file is set", %{dir: dir} do
      path = Path.join(dir, ".aiurconfig")
      File.write!(path, "tracker:\n  kind: memory\nprewarm:\n  enabled: true\n  base_build: echo hi\n")

      assert {:ok, loaded} = Workflow.load(path)
      assert loaded.config["prewarm"]["base_build"] == "echo hi"
    end
  end

  describe "config path resolution" do
    test "workflow_file_path defaults to .aiur/config in cwd when app env unset", %{dir: dir} do
      File.cd!(dir, fn ->
        Application.delete_env(:aiur, :workflow_file_path)
        path = Workflow.workflow_file_path()
        assert Path.basename(path) == "config"
        assert Path.basename(Path.dirname(path)) == ".aiur"
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

    test "resolve_config_path follows .aiur/config > .aiurconfig > ~/.aiur/config > ~/.aiurconfig", %{
      dir: dir
    } do
      repo_new = Path.join([dir, "repo", ".aiur", "config"])
      repo_legacy = Path.join([dir, "repo", ".aiurconfig"])
      global_new = Path.join([dir, "home", ".aiur", "config"])
      global_legacy = Path.join([dir, "home", ".aiurconfig"])
      candidates = [repo_new, repo_legacy, global_new, global_legacy]

      # none present -> the new repo-local default (so the caller surfaces "run aiur init")
      assert Workflow.resolve_config_path(candidates) == repo_new

      write_config = fn path ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "tracker:\n  kind: memory\n")
      end

      # only legacy global -> legacy global
      write_config.(global_legacy)
      assert Workflow.resolve_config_path(candidates) == global_legacy

      # global new beats legacy global
      write_config.(global_new)
      assert Workflow.resolve_config_path(candidates) == global_new

      # legacy repo beats anything global
      write_config.(repo_legacy)
      assert Workflow.resolve_config_path(candidates) == repo_legacy

      # new repo-local wins outright
      write_config.(repo_new)
      assert Workflow.resolve_config_path(candidates) == repo_new
    end

    # Anchored at the *effective* HOME, not `Path.expand("~")`. The latter
    # resolves the home the VM captured at boot and ignores a later
    # `System.put_env`, which silently defeated the suite's HOME sandbox and let
    # discovery reach the developer's real `~/.aiur/config`.
    test "config_path_candidates is the 4-step precedence list anchored at cwd and home", %{dir: dir} do
      home = System.get_env("HOME")

      File.cd!(dir, fn ->
        assert [repo_new, repo_legacy, global_new, global_legacy] = Workflow.config_path_candidates()
        assert repo_new == Path.join([File.cwd!(), ".aiur", "config"])
        assert repo_legacy == Path.join(File.cwd!(), ".aiurconfig")
        assert global_new == Path.join([home, ".aiur", "config"])
        assert global_legacy == Path.join(home, ".aiurconfig")
      end)
    end

    test "a runtime HOME change is honored, so the suite's sandbox actually holds", %{dir: dir} do
      previous_home = System.get_env("HOME")
      System.put_env("HOME", "/tmp/aiur-home-probe")

      try do
        File.cd!(dir, fn ->
          assert [_repo_new, _repo_legacy, global_new, _global_legacy] = Workflow.config_path_candidates()
          assert global_new == "/tmp/aiur-home-probe/.aiur/config"
        end)
      after
        if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")
      end
    end
  end
end
