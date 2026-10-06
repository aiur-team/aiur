defmodule Aiur.NonElixirValidationInstallTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentSkills, Issue, PromptBuilder, Workflow}

  setup do
    workspace = Aiur.TestSupport.tmp_root!("typescript-validation")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "package.json"), ~s({"private":true,"scripts":{"verify:unit":"vitest run"}}))
    File.write!(Path.join(workspace, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n")
    File.mkdir_p!(Path.join(workspace, "apps/web/src"))
    File.write!(Path.join(workspace, "apps/web/src/footer.test.ts"), "// colocated test fixture\n")
    previous = Application.get_env(:aiur, :workflow_file_path)
    config = Path.join(workspace, "workflow.yaml")
    File.write!(config, "tracker:\n  kind: memory\n  base_branch: main\nagent:\n  kind: claude\n")
    Workflow.set_workflow_file_path(config)

    on_exit(fn ->
      if is_nil(previous), do: Workflow.clear_workflow_file_path(), else: Workflow.set_workflow_file_path(previous)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "TypeScript workspace receives repository-aware validation through the real skill installer", %{workspace: workspace} do
    refute File.exists?(Path.join(workspace, "mix.exs"))
    refute File.exists?(Path.join(workspace, "src/mix.exs"))
    assert :ok = AgentSkills.install(workspace)

    for directory <- [".claude", ".codex"] do
      skill = Path.join([workspace, directory, "skills", "aiur-agent"])
      entry = File.read!(Path.join(skill, "SKILL.md"))
      loop = File.read!(Path.join(skill, "dev-loop.md")) |> one_line()
      validation = File.read!(Path.join(skill, "validation.md")) |> one_line()

      assert entry =~ "`validation.md`"
      assert loop =~ "[`validation.md`](validation.md)"
      assert loop =~ "The Elixir examples below apply only to Aiur's Elixir core"
      assert loop =~ "follow that repository's documentation policy"
      assert loop =~ "for Aiur changes, use `website/docs-app/`"
      assert validation =~ "inspect package.json scripts and the selected runner's file filters"
      assert validation =~ "including colocated tests and sibling files"
      assert validation =~ "test fails with the production change reverted in an isolated worktree"
      assert validation =~ "not a prohibition on focused repository tests"
    end
  end

  test "cold and continuation prompts preserve focused tests without imposing the Aiur runner" do
    issue = %Issue{identifier: "TS-1", title: "Fix footer", description: "Update the TypeScript footer", labels: []}
    cold = PromptBuilder.build_prompt(issue) |> one_line()
    continuation = PromptBuilder.rename_test_audit_restatement() |> one_line()

    for prompt <- [cold, continuation] do
      assert prompt =~ "Run focused tests using the target repository's documented commands"
      assert prompt =~ "does not prohibit focused repository tests"
      assert prompt =~ "colocated tests"
    end

    assert cold =~ "examples below apply only to Aiur's Elixir core"
    assert continuation =~ "Only for Aiur's Elixir core"
  end

  defp one_line(text), do: String.replace(text, ~r/\s+/, " ")
end
