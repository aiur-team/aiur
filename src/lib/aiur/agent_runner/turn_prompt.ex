defmodule Aiur.AgentRunner.TurnPrompt do
  @moduledoc false

  alias Aiur.{Issue, PromptBuilder}

  defp turn_of(nil), do: ""
  defp turn_of(max_turns), do: " of #{max_turns}"

  @doc false
  @spec build_turn_prompt(Issue.t(), keyword(), pos_integer(), pos_integer() | nil) :: String.t()
  def build_turn_prompt(issue, opts, 1, _max_turns) do
    case first_turn_mode(issue, opts) do
      :resumed -> resumed_turn_prompt()
      :continuation -> continuation_turn_prompt(issue, opts, continuation_reason(issue))
      :cold -> PromptBuilder.build_prompt(issue, opts)
    end
  end

  def build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous turn completed normally, but the issue is still in an active state.
    - This is continuation turn ##{turn_number}#{turn_of(max_turns)} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - If you just completed `ce-plan`, proceed directly to `ce-work` — the planning-to-work transition is authorized on active tickets without an operator message. Pause only if planning surfaced an unresolved operator decision, a dependency blocker, or a scope question that genuinely requires human input before implementation can begin.
    - If manual `scripts/aiurdev --test` / `--test3` is blocked inside this agent workspace, stop that verification path and report it; do not retry from `/tmp`, a copied harness, or another clone.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  @doc """
  Which first-turn prompt a dispatch gets.

  `:resumed` wins over prior work — the codex thread was reattached, so the
  agent already has every prior turn and only needs a nudge. `:continuation`
  covers a *cold* thread that nonetheless has prior work to continue from:
  either the ticket is in `rework`, or the orchestrator recycled a ticket it had
  already run (`prior_work: true`). Everything else is a genuine cold start.
  """
  @spec first_turn_mode(Issue.t(), keyword()) :: :resumed | :continuation | :cold
  def first_turn_mode(issue, opts) do
    cond do
      Keyword.get(opts, :resumed, false) -> :resumed
      rework_state?(issue.state) -> :continuation
      Keyword.get(opts, :prior_work, false) == true -> :continuation
      true -> :cold
    end
  end

  defp continuation_reason(issue) do
    if rework_state?(issue.state), do: :rework, else: :prior_work
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
    - If the prior turn completed `ce-plan`, proceed directly to `ce-work` — the planning-to-work transition is authorized on active tickets without an operator message. Pause only if planning surfaced an unresolved operator decision, a dependency blocker, or a scope question that genuinely requires human input before implementation can begin.
    - If manual `scripts/aiurdev --test` / `--test3` is blocked inside this agent workspace, stop that verification path and report it; do not retry from `/tmp`, a copied harness, or another clone.
    - Do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  # First-turn prompt for a ticket dispatched cold in `rework`. The prior run
  # already brainstormed, planned, and implemented this ticket; it is back only
  # to address review feedback. When the codex thread is resumable the caller
  # takes the `:resumed` branch above (full prior context intact); this branch
  # is the cold-rework case. Keep the normal prompt's ticket identity and
  # operating contract, but put explicit continuation guidance first so the
  # agent does not repeat brainstorm/plan work.
  defp continuation_turn_prompt(issue, opts, reason) do
    continuation = """
    Continuation guidance (#{continuation_headline(reason)}):

    - #{continuation_why(reason)} Do NOT re-run ce-brainstorm or ce-plan and do not restart the ticket from scratch.
    - #{continuation_orientation(reason)}
    - Reconcile against the current workspace and workpad state before acting; a few things may have changed since the prior run.
    - You may revise the prior plan only if the new evidence makes that approach wrong — and if you do, record why in the `## Agent Workpad` before changing course.
    - If manual `scripts/aiurdev --test` / `--test3` is blocked inside this agent workspace, stop that verification path and report it; do not retry from `/tmp`, a copied harness, or another clone.
    - Do not end the turn while the issue stays active unless you are truly blocked.
    """

    continuation <>
      "\nTicket operating contract and context follow. Use them for identity, lifecycle, and repository rules; the continuation guidance above supersedes their generic cold-start phase order.\n\n" <>
      PromptBuilder.build_prompt(issue, opts)
  end

  defp continuation_headline(:rework), do: "this issue is in rework"
  defp continuation_headline(:prior_work), do: "this agent run continues prior work on this ticket"

  defp continuation_why(:rework),
    do: "This ticket was already brainstormed, planned, and implemented in a prior run; it is back in `rework` only to address review feedback."

  defp continuation_why(:prior_work),
    do: "A prior agent run on this ticket already did work (it reached its turn limit or was replaced), and this run continues it — the branch, workspace, and workpad already exist."

  defp continuation_orientation(:rework),
    do: "Read the existing `## Agent Workpad` and the unresolved PR review feedback, then make the specific changes the review asks for."

  defp continuation_orientation(:prior_work),
    do:
      "Read the existing `## Agent Workpad`, the branch's commits, and any open PR to establish what is already done, then continue from that handoff — start at the phase the workpad says is next, not at brainstorm."

  @spec rework_state?(term()) :: boolean()
  defp rework_state?(state) when is_binary(state) do
    normalized = String.downcase(state)
    normalized == "rework" or normalized == "agent:rework"
  end

  defp rework_state?(_state), do: false
end
