defmodule Aiur.AgentRunner.TurnPrompt do
  @moduledoc false

  alias Aiur.{Issue, PromptBuilder}

  defp turn_of(nil), do: ""
  defp turn_of(max_turns), do: " of #{max_turns}"

  @doc false
  @spec build_turn_prompt(Issue.t(), keyword(), pos_integer(), pos_integer() | nil) :: String.t()
  def build_turn_prompt(issue, opts, 1, _max_turns) do
    if Keyword.get(opts, :resumed, false) do
      resumed_turn_prompt()
    else
      PromptBuilder.build_prompt(issue, opts)
    end
  end

  def build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous turn completed normally, but the issue is still in an active state.
    - This is continuation turn ##{turn_number}#{turn_of(max_turns)} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - If manual `scripts/aiurdev --test` / `--test3` is blocked inside this agent workspace, stop that verification path and report it; do not retry from `/tmp`, a copied harness, or another clone.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  # First-turn prompt for a session resumed after an aiur restart. The codex
  # thread was reattached, so the full original task + every prior turn is
  # already intact in the conversation — replaying the cold-start prompt would
  # make the agent re-discover work it has already done (the exact waste #378
  # removes). This is semantically the same nudge as an in-process continuation
  # turn, just across a restart boundary.
  defp resumed_turn_prompt do
    """
    Continuation guidance (session resumed after an aiur restart):

    - Aiur restarted and reattached this agent to its prior session, so the full original task instructions and every prior turn are already present in this thread.
    - Do not restart from scratch and do not re-read the issue, labels, or workpad to rebuild context you already have — continue from where you left off.
    - Reconcile against the current workspace and workpad state (a few things may have changed while aiur was down), then resume the remaining ticket work.
    - If manual `scripts/aiurdev --test` / `--test3` is blocked inside this agent workspace, stop that verification path and report it; do not retry from `/tmp`, a copied harness, or another clone.
    - Do not end the turn while the issue stays active unless you are truly blocked.
    """
  end
end
