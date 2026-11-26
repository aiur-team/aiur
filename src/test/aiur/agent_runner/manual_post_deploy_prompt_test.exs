defmodule Aiur.AgentRunner.ManualPostDeployPromptTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @shared_prompt Path.join(@repo_root, "src/prompts/shared-agent-instructions.md")
  @agent_dev_loop Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md")

  test "treats a slow build gate as a wait and uses a resume state at time limits" do
    prompt = File.read!(@shared_prompt)
    gate_guidance = String.split(prompt, "### Slow shared build gate", parts: 2) |> List.last()

    assert gate_guidance =~ "keep waiting for it to finish"
    assert gate_guidance =~ "instead of retrying it, ending the session, or"
    assert gate_guidance =~ "setting `agent:error`"
    assert gate_guidance =~ "aiur_set_ticket_state({\"state\": \"rework\"})"
    assert gate_guidance =~ "end the turn with the workspace and workpad intact"
    assert gate_guidance =~ "Aiur's normal continuation/recycle path can resume it"
    assert gate_guidance =~ "Never set"
    assert gate_guidance =~ "`agent:error` just because time ran out"
    assert gate_guidance =~ "existing workspace rather than restart setup"
  end

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
