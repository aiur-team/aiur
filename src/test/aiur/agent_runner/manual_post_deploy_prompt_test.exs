defmodule Aiur.AgentRunner.ManualPostDeployPromptTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @shared_prompt Path.join(@repo_root, "src/prompts/shared-agent-instructions.md")
  @agent_dev_loop Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md")

  test "routes workspace-inaccessible hands-on checks to explicit post-deploy gates" do
    prompt = File.read!(@shared_prompt)

    assert prompt =~ "do not raise an operator decision and do not pause"
    assert prompt =~ "Post-deploy check: <exact steps>"
    assert prompt =~ "operator: physical Stream Deck"

    dev_loop = File.read!(@agent_dev_loop)
    manual_check = String.split(dev_loop, "## Manual CLI verification before opening a PR", parts: 2) |> List.last()
    assert manual_check =~ "when the workspace can do so"
    assert manual_check =~ "do not raise a decision or pause"
    assert manual_check =~ "## Local tests"
  end
end
