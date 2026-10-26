defmodule Aiur.Orchestrator.HoldDecline do
  @moduledoc """
  Classifies a failed dispatch-time GitHub read as a retry or an attention
  item (#4067).

  A read refused by the local budget guard is pacing, not a fault: the next
  poll retries it. Such a decline is recorded as `:github_budget_hold` at info
  and only becomes the attention decline (`fallback`) once
  `Aiur.GitHub.HoldPressure` has seen it repeat, with no read getting through
  in between, past the configured threshold. Every other failure keeps the
  fail-closed attention decline unchanged.
  """

  require Logger

  alias Aiur.GitHub.HoldPressure
  alias Aiur.Issue
  alias Aiur.Orchestrator.State

  @hold_reason :github_budget_hold

  @doc "The non-attention decline reason recorded for a transient hold."
  @spec hold_reason() :: :github_budget_hold
  def hold_reason, do: @hold_reason

  @doc """
  Logs the failure and returns the decline reason to record: `hold_reason/0`
  for a local hold still under the threshold, `fallback` otherwise.
  """
  @spec classify(Issue.t(), term(), atom(), keyword()) :: atom()
  def classify(%Issue{} = issue, failure, fallback, opts \\ []) when is_atom(fallback) and is_list(opts) do
    hold? = local_hold?(failure)
    # A different failure ends the run of holds; an escalated hold does not.
    if not hold?, do: HoldPressure.dispatch_cleared(issue.id, opts)

    if hold? and HoldPressure.dispatch_decline(issue.id, opts) == :transient do
      Logger.info("Dispatch deferred by a local GitHub budget hold; retrying next poll: #{State.issue_context(issue)} failure=#{inspect(failure)}")
      @hold_reason
    else
      Logger.warning("Skipping dispatch (fail-closed, #{fallback}): #{State.issue_context(issue)} failure=#{inspect(failure)}")
      fallback
    end
  end

  @doc """
  Passes a settled validation through, ending the ticket's run of holds.

  Call it only where every read of the validation got through: on the issue
  held by a dependency before any refresh, or on the hydration that follows a
  successful refresh. Clearing on the earlier blocker read alone would let a
  refresh that is held every poll restart the run each time and never escalate.
  """
  @spec observe(result) :: result when result: term()
  def observe(%Issue{id: id} = issue) do
    HoldPressure.dispatch_cleared(id)
    issue
  end

  def observe({:ok, %Issue{} = issue} = result) do
    observe(issue)
    result
  end

  def observe(result), do: result

  defp local_hold?({:error, reason}), do: local_hold?(reason)
  defp local_hold?({:github, :local_hold, _detail}), do: true
  defp local_hold?({:aiur, :locally_held, _hold}), do: true
  defp local_hold?(_failure), do: false
end
