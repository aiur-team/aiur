defmodule Aiur.PromptBuilderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Issue
  alias Aiur.PromptBuilder
  alias Aiur.Workflow

  setup %{config: config} do
    previous = Application.get_env(:aiur, :workflow_file_path)

    dir = Path.join(System.tmp_dir!(), "aiur-prompt-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, ".aiurconfig")
    File.write!(path, config)
    Workflow.set_workflow_file_path(path)

    on_exit(fn ->
      File.rm_rf!(dir)

      if is_nil(previous) do
        Workflow.clear_workflow_file_path()
      else
        Workflow.set_workflow_file_path(previous)
      end
    end)

    :ok
  end

  defp issue(labels) do
    %Issue{identifier: "ABC-1", title: "A task", description: "do the thing", labels: labels}
  end

  @config """
  tracker:
    kind: memory
  agent:
    kind: claude
    complexity_prompts:
      3: "Medium complexity: prefer incremental commits."
  """

  @tag config: @config
  test "appends the configured guidance for the issue's complexity level" do
    prompt = PromptBuilder.build_prompt(issue(["complexity:3"]))

    assert String.ends_with?(prompt, "Medium complexity: prefer incremental commits.")
  end

  @tag config: @config
  test "does not append when no guidance is configured for that level" do
    prompt = PromptBuilder.build_prompt(issue(["complexity:2"]))

    refute String.contains?(prompt, "Medium complexity")
  end

  @tag config: @config
  test "does not append when the issue has no complexity label" do
    prompt = PromptBuilder.build_prompt(issue([]))

    refute String.contains?(prompt, "Medium complexity")
  end

  @tag config: """
       tracker:
         kind: memory
       agent:
         kind: claude
         complexity_prompts:
           3: "   "
       """
  test "blank guidance for a level is treated as no guidance" do
    prompt = PromptBuilder.build_prompt(issue(["complexity:3"]))

    refute String.ends_with?(prompt, "   ")
  end

  @tag config: @config
  test "shared prompt points at the /aiur-agent skill for cross-ticket events" do
    prompt = PromptBuilder.build_prompt(issue([]))

    assert String.contains?(prompt, "/aiur-agent")
  end

  @tag config: @config
  test "shared prompt no longer inlines the cross-ticket event vocabulary" do
    prompt = PromptBuilder.build_prompt(issue([]))

    # The allowlisted vocabulary now lives only in the /aiur-agent skill's
    # event-taxonomy.md. Guards #382: no parallel copy in the pre-prompt.
    refute String.contains?(prompt, "Event vocabulary (allowlisted")
    refute String.contains?(prompt, "You can re-block")
  end

  @tag config: @config
  test "shared prompt keeps the operator-bar progress protocol (not moved to the skill)" do
    prompt = PromptBuilder.build_prompt(issue([]))

    # The bare `progress` / `progress.checkin` operator-bar protocol is
    # deliberately NOT part of /aiur-agent — guard against an over-zealous slim
    # that strips it along with the cross-ticket vocabulary.
    assert String.contains?(prompt, "Progress emits")
    assert String.contains?(prompt, "Executor check-ins")
  end

  @tag config: @config
  test "routes hardware acceptance criteria to the operator in the agent prompt" do
    hardware_issue = %Issue{identifier: "HID-1", title: "HID", description: "## Acceptance\n- Read /dev/hidraw0 then press the dial."}

    prompt = PromptBuilder.build_prompt(hardware_issue)

    assert prompt =~ "Hardware-dependent acceptance criteria"
    assert prompt =~ "report_untestable"
    assert prompt =~ "agent:operator-verified"
    assert prompt =~ "operator-verification-passed"
    assert prompt =~ "CI blind spot"
  end

  @tag config: @config
  test "shared prompt tells agents not to retry blocked manual-test guards" do
    prompt = PromptBuilder.build_prompt(issue([]))

    assert String.contains?(prompt, "manual --test runs are blocked inside agent")
    assert String.contains?(prompt, "Do not retry by copying the repo to")
    assert String.contains?(prompt, "Executor-root manual test runs are allowed")
  end

  @tag config: @config
  test "shared prompt points at the using-aiur operating-manual skill" do
    prompt = PromptBuilder.build_prompt(issue([]))

    assert String.contains?(prompt, "using-aiur")
  end

  @tag config: """
       tracker:
         kind: github
         base_branch: integration
         github:
           repo: owner/repo
           planning_root_limit: 100
           planning_page_budget: 4
           planning_call_budget: 4
       agent:
         kind: codex
       """
  test "identifies the configured integration branch as authoritative" do
    {prompt, log} = with_log(fn -> PromptBuilder.build_prompt(issue([])) end)

    assert prompt =~ "configured `tracker.base_branch` is `integration`"
    assert prompt =~ ~s(--base "$AIUR_BASE_BRANCH")
    assert prompt =~ "never from `origin/HEAD`"
    assert log =~ "Authoritative integration branch"
    assert log =~ ~s(tracker.base_branch="integration")
  end

  @tag config: @config
  test "shared prompt no longer inlines the general operating manual" do
    prompt = PromptBuilder.build_prompt(issue([]))

    # The label lifecycle, complexity routing, CODEOWNERS authority, PR shape,
    # and milestone-alert names moved into the `using-aiur` skill (#370). Guard
    # against a regression that re-inlines them into every per-turn prompt.
    refute String.contains?(prompt, "### Complexity routing")
    refute String.contains?(prompt, "### Whose comments to act on")
    refute String.contains?(prompt, "### PR description shape")
  end
end
