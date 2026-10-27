defmodule Aiur.AgentGitHubGuard.PromptTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  test "GitHub guard failures preserve their diagnostic in agent alerts" do
    prompt =
      Path.join(@repo_root, "src/prompts/shared-agent-instructions.md")
      |> File.read!()
      |> String.replace(~r/\s+/u, " ")

    assert prompt =~ "include that exact diagnostic in any alert or decision"
    assert prompt =~ "do not replace it with a generic \"GitHub is stuck\" summary"
  end
end
