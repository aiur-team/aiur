defmodule Aiur.PromptBuilderTest do
  use ExUnit.Case, async: false

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
    assert String.contains?(prompt, "Operator check-ins")
  end

  @tag config: @config
  test "shared prompt tells agents not to retry blocked manual-test guards" do
    prompt = PromptBuilder.build_prompt(issue([]))

    assert String.contains?(prompt, "manual --test runs are blocked inside agent")
    assert String.contains?(prompt, "Do not retry by copying the repo to")
    assert String.contains?(prompt, "Operator-root manual test runs are allowed")
  end
end
