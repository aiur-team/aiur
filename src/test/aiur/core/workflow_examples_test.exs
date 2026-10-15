defmodule Aiur.Core.WorkflowExamplesTest do
  use Aiur.TestSupport
  alias Aiur.Config.Schema

  test "checked-in workflow examples parse and portable examples stay generic" do
    example_paths = Path.wildcard("examples/workflows/*.yaml")

    assert Enum.sort(example_paths) ==
             Enum.sort([
               "examples/workflows/github-claude.yaml",
               "examples/workflows/github-codex.yaml",
               "examples/workflows/github-muse.yaml",
               "examples/workflows/linear-codex.yaml"
             ])

    assert Path.wildcard("examples/workflows/*.aiurconfig") == []

    workflow_paths = example_paths ++ Path.wildcard("../.aiur/config")

    assert Enum.any?(workflow_paths)

    for path <- workflow_paths do
      assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(path)
      assert {:ok, _settings} = Schema.parse(config)
      assert String.trim(prompt) != ""
    end

    portable_paths = example_paths ++ Path.wildcard("examples/workflows/*.prompt.md")

    machine_local_pattern = ~r/(\/home\/|100\.\d+\.\d+\.\d+|applekid|orangekid|its-applekid|ethereum-optimism)/

    for path <- portable_paths do
      refute File.read!(path) =~ machine_local_pattern
    end
  end

  test "GitHub workflow examples load effective planning settings" do
    original_workflow_path = Workflow.workflow_file_path()

    try do
      for path <- [
            "examples/workflows/github-codex.yaml",
            "examples/workflows/github-claude.yaml",
            "examples/workflows/github-muse.yaml"
          ] do
        Workflow.set_workflow_file_path(Path.expand(path))
        settings = Config.settings!()

        assert settings.tracker.github.repo == "your-org/your-repo"
        assert settings.tracker.github.planning_root_limit == 100
        assert settings.tracker.github.planning_page_budget == 4
        assert settings.tracker.github.planning_call_budget == 4
      end
    after
      Workflow.set_workflow_file_path(original_workflow_path)
    end
  end

  test "Codex workflow examples carry explicit settings into every startup frame" do
    original_workflow_path = Workflow.workflow_file_path()
    original_path = System.get_env("PATH")
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workflow-codex-frames")
    workspace = Path.join(test_root, "workspace")
    codex_binary = Path.join(test_root, "codex")
    trace_file = Path.join(test_root, "codex.trace")

    try do
      File.mkdir_p!(workspace)
      System.put_env("PATH", test_root <> ":" <> original_path)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$SYMP_TEST_CODEX_TRACE"
        case "$line" in
          *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
          *'"method":"thread/start"'*|*'"method":"thread/resume"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-example"}}}' ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-example"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      for path <- ["examples/workflows/github-codex.yaml", "examples/workflows/linear-codex.yaml"] do
        fixture_path = Path.join(test_root, Path.basename(path))

        File.cp!(Path.expand(path), fixture_path)
        prompt_path = Path.rootname(path) <> ".prompt.md"
        File.cp!(Path.expand(prompt_path), Path.join(test_root, Path.basename(prompt_path)))

        fixture_path
        |> File.read!()
        |> String.replace("  root: ~/code/aiur-workspaces", "  root: #{test_root}")
        |> String.replace("    thread_sandbox: workspace-write", "    thread_sandbox: read-only\n    turn_sandbox_policy: {type: readOnly}")
        |> then(&File.write!(fixture_path, &1))

        Workflow.set_workflow_file_path(fixture_path)
        issue = %Issue{id: "example-#{path}", identifier: "EXAMPLE", title: "Check frames", state: "In Progress"}

        assert {:ok, _} = AppServer.run(workspace, "start", issue)
        assert {:ok, _} = AppServer.run(workspace, "resume", issue, resume_thread_id: "thread-example")

        frames =
          trace_file
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim_leading(&1, "JSON:"))
          |> Enum.map(&Jason.decode!/1)

        assert Enum.any?(frames, &example_thread_frame?(&1, "thread/start"))
        assert Enum.any?(frames, &example_thread_frame?(&1, "thread/resume"))
        assert Enum.any?(frames, &example_turn_frame?/1)
        File.rm!(trace_file)
      end
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      System.put_env("PATH", original_path)
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "checked-in Codex GitHub workflows preserve enough turn budget and handoff context" do
    workflow_paths = [
      "examples/workflows/github-codex.yaml",
      "../.aiur/config"
    ]

    for path <- workflow_paths do
      assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(path)

      assert get_in(config, ["agent", "max_turns"]) >= 12
      assert prompt =~ "handoff"
      assert prompt =~ "current phase"
      assert prompt =~ "validation"
      assert prompt =~ "next steps"
    end
  end

  defp example_thread_frame?(%{"method" => method, "params" => params}, method) do
    params["approvalPolicy"] == "never" and params["sandbox"] == "read-only"
  end

  defp example_thread_frame?(_, _), do: false

  defp example_turn_frame?(%{"method" => "turn/start", "params" => params}) do
    params["approvalPolicy"] == "never" and params["sandboxPolicy"] == %{"type" => "readOnly"}
  end

  defp example_turn_frame?(_), do: false
end
