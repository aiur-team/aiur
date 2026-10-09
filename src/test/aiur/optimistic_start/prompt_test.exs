defmodule Aiur.OptimisticStart.PromptTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.TurnPrompt
  alias Aiur.{Issue, PromptBuilder, Workflow}

  @sha String.duplicate("a", 40)
  @ref "refs/heads/aiur/12-work"

  setup do
    previous = Application.get_env(:aiur, :workflow_file_path)
    dir = Aiur.TestSupport.tmp_root!("optimistic-prompt")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config")
    File.write!(path, "tracker:\n  kind: memory\n  base_branch: main\n")
    Workflow.set_workflow_file_path(path)

    on_exit(fn ->
      File.rm_rf!(dir)
      if previous, do: Workflow.set_workflow_file_path(previous), else: Workflow.clear_workflow_file_path()
    end)

    :ok
  end

  test "ordinary prompt stays byte identical" do
    prompt = PromptBuilder.build_prompt(issue(nil))
    assert Base.encode16(:crypto.hash(:sha256, prompt)) == "6E170AC6455E87D475F1AB89AA1CB192D9771A082B9F8AF56B16787656962AEC"
    refute prompt =~ "## Optimistic start"
  end

  test "single blocker carries its SHA, ancestry check and PR base on every turn path" do
    issue = issue(record([blocker("12")]))

    for {opts, turn} <- [{[], 1}, {[prior_work: true], 1}, {[resumed: true], 1}, {[], 2}] do
      prompt = TurnPrompt.build_turn_prompt(issue, opts, turn, 4)
      assert prompt =~ "## Optimistic start"
      assert prompt =~ @ref
      assert prompt =~ @sha
      assert prompt =~ "merge-base --is-ancestor #{@sha} HEAD"
      assert prompt =~ "--base aiur/12-work"
      assert prompt =~ "draft"
      assert prompt =~ "ci-wait"
    end
  end

  test "fan-in lists both blockers and targets the configured base" do
    prompt = PromptBuilder.build_prompt(issue(record([blocker("12"), blocker("13")])))
    assert prompt =~ "refs/heads/aiur/12-work"
    assert prompt =~ "refs/heads/aiur/13-work"
    assert prompt =~ "--base \"$AIUR_BASE_BRANCH\""
  end

  test "unsafe refs are omitted and require resolving the ticket branch" do
    unsafe = %{blocker("12") | ref: "refs/heads/aiur/12-work\n$(echo injected)"}
    prompt = PromptBuilder.build_prompt(issue(record([unsafe])))
    refute prompt =~ "$(echo injected)"
    assert prompt =~ "scripts/resolve-ticket-branch 12"
    refute prompt =~ "--base aiur/12-work"
  end

  defp issue(record), do: Map.put(%Issue{id: "22", identifier: "22", title: "Work", description: "Task"}, :optimistic_start, record)
  defp blocker(id), do: %{identifier: id, pr_number: 99, ref: "refs/heads/aiur/#{id}-work", sha: @sha}
  defp record([only]), do: %{blockers: [only], primary: only.identifier, pr_base: only.ref, started_at: DateTime.utc_now()}
  defp record(blockers), do: %{blockers: blockers, primary: nil, pr_base: :base_branch, started_at: DateTime.utc_now()}
end
