defmodule Aiur.OptimisticStartPromptContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  test "shared prompt separates optimistic integration from paused-dependent readiness" do
    prompt =
      @repo_root
      |> Path.join("src/prompts/shared-agent-instructions.md")
      |> File.read!()
      |> String.replace(~r/\s+/, " ")

    [_, optimistic] = String.split(prompt, "- **Optimistic start.**", parts: 2)
    [optimistic, paused] = String.split(optimistic, "- **Resume on explicit unblocked; inspect branch pushes.**", parts: 2)
    [paused | _] = String.split(paused, "- **Producers push before unblocking.**", parts: 2)

    for phrase <- [
          "If your prompt has an Optimistic start block",
          "every blocker push is an integration signal",
          "next safe checkpoint",
          "WIP committed, no test run in flight",
          "Integrate only direct blockers listed in that block",
          "never merge a grand-blocker's push or a newer integration branch into your still-stacked branch",
          "Updates cascade level by level through direct blocker pushes",
          "Rebase on rewritten history",
          "--force-with-lease",
          "Keep the PR draft and stacked",
          "never mark ready while any blocker PR is unmerged",
          "stub-then-fetch.md#optimistic-start-started-on-an-unmerged-blocker"
        ] do
      assert optimistic =~ phrase
    end

    assert paused =~ "For paused dependents"
    assert paused =~ "ticket.N.agent.unblocked"
    assert paused =~ "Never infer readiness from `branch.push` alone"
  end
end
