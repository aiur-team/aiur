defmodule Aiur.AgentRunner.MergePolicyPrompt do
  @moduledoc false

  @spec build(map()) :: String.t()
  def build(policy) do
    """
    ## Local tests policy

    `merge_policy.local_tests` is currently `#{policy.local_tests}`. This current policy supersedes older local-test instructions.
    #{instructions(policy.local_tests)}
    The AGENTS.md revert check for new tests applies in every mode, including `none`.
    Record evidence under `## Local tests` in every PR body: `Policy`, `Tested head` (the full 40-character pushed commit SHA),
    `Base` (ref and SHA), `Selection` (why these tests cover the change), and command bullets: ``- `command` -> result``.
    Record actual results, including failures or blockers. Update the evidence after every push; never claim unrun tests passed.
    #{ci_note(policy.ci)}

    """
  end

  defp instructions("all"), do: "Before marking the PR ready, run the full local test suite for this repo. Record each command and its result in the PR body."

  defp instructions("partial") do
    "Run only tests relevant to your change: tests you changed, the mirror test of each changed source file, " <>
      "tests of direct callers of changed modules, and tests that still use a name you deleted. " <>
      "If the change touches shared test support, build files, dependency files or runtime config, or selection is unsafe for unknown file types, run the full suite instead. " <>
      "Use the target repository's setup notes to choose its test-selection tool and commands."
  end

  defp instructions("none"), do: "Run compile and format checks. CI is the test gate."

  defp ci_note("pending_ok") do
    "Your PR may merge before CI finishes, on this evidence. A missing or stale `Local tests` section makes it wait for CI."
  end

  defp ci_note("wait"), do: "Full required CI must pass before human-review handoff."
end
