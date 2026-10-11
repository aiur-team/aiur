defmodule Aiur.MergePolicyPromptTest do
  use ExUnit.Case, async: false
  alias Aiur.AgentRunner.{MergePolicyPrompt, TurnPrompt}
  alias Aiur.{Issue, PromptBuilder, Workflow}

  setup do
    previous = Application.get_env(:aiur, :workflow_file_path)
    root = Aiur.TestSupport.tmp_root!("mp3-prompt")
    File.mkdir_p!(root)
    path = Path.join(root, "config.yaml")

    on_exit(fn ->
      if previous, do: Workflow.set_workflow_file_path(previous), else: Workflow.clear_workflow_file_path()
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{path: path}
  end

  test "renders each mode and only pending_ok carries the early merge note" do
    for {mode, text} <- [{"all", "run the full local test suite"}, {"partial", "tests of direct callers"}, {"none", "Run compile and format checks"}] do
      prompt = MergePolicyPrompt.build(%{local_tests: mode, ci: "wait"})
      assert prompt =~ "currently `#{mode}`"
      assert prompt =~ text
      assert prompt =~ "revert check for new tests applies in every mode, including `none`"
      assert prompt =~ "full 40-character pushed commit SHA"
      refute prompt =~ "may merge before CI"
    end

    partial = MergePolicyPrompt.build(%{local_tests: "partial", ci: "pending_ok"})
    assert partial =~ "shared test support, build files, dependency files or runtime config"
    assert partial =~ "tests that still use a name you deleted"
    assert partial =~ "may merge before CI finishes"
    assert partial =~ "missing or stale `Local tests` section"
  end

  test "cold, resumed, rework and subsequent turns use current config", %{path: path} do
    configure(path, "partial")
    issue = %Issue{id: "3879", identifier: "3879", title: "MP3", description: "evidence", labels: []}
    assert PromptBuilder.build_prompt(issue) =~ "currently `partial`"
    assert TurnPrompt.build_turn_prompt(issue, [resumed: true], 1, nil) =~ "currently `partial`"

    configure(path, "none")

    for opts <- [[], [resumed: true], [prior_work: true]] do
      assert TurnPrompt.build_turn_prompt(issue, opts, 1, nil) =~ "currently `none`"
    end

    assert TurnPrompt.build_turn_prompt(%{issue | state: "rework"}, [], 1, nil) =~ "currently `none`"
    assert TurnPrompt.build_turn_prompt(issue, [], 2, nil) =~ "currently `none`"
    assert PromptBuilder.merge_policy_restatement() =~ "currently `none`"
  end

  defp configure(path, mode) do
    File.write!(path, "tracker:\n  kind: memory\n  base_branch: main\nmerge_policy:\n  local_tests: #{mode}\n")
    Workflow.set_workflow_file_path(path)
  end
end
